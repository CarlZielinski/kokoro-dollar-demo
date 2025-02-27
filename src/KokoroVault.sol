// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./KokoroUSD.sol";
import "./AggregatorV3Interface.sol";

/**
 * @title KokoroVault
 * @notice Simplified vault/CDP with consistent ETH→USD→kUSD scaling.
 *
 *         - depositUSD = (ethPrice * depositWei) / 1e8
 *           Example: If price = 1800e8 and msg.value=1e18 => depositUSD=1.8e21 
 *           (i.e. 1800 * 1e18).
 *
 *         - minted kUSD = depositUSD * (10000 / collateralRatioBps)
 *           Example: ratio=150% => ratio=15000 => minted= depositUSD*(10000/15000)
 *
 *         - For ratio checks, depositUSD is similarly computed, then compare
 *           depositUSD*(10000)/userDebt (since userDebt is in 1e18 decimals).
 */
contract KokoroVault is AccessControl, ReentrancyGuard {
    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Collateral ratio in basis points (e.g., 15000 => 150%)
    uint256 public collateralRatioBps = 15000;

    // Liquidation threshold in basis points (e.g., 12000 => 120%)
    uint256 public liquidationThresholdBps = 12000;

    // Each user’s total ETH deposit
    mapping(address => uint256) public deposits;

    // External references
    KokoroUSD public kokoroUSD;
    AggregatorV3Interface public priceFeed;
    address public restakeEOA;

    // If the vault’s total ETH >= 32, auto-restake
    uint256 public constant RESTAKE_THRESHOLD = 32 ether;

    constructor(
        address _kUSD,
        address _restakeEOA,
        address _priceFeed
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        kokoroUSD = KokoroUSD(_kUSD);
        restakeEOA = _restakeEOA;
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    /**
     * @dev Deposit ETH, mint kUSD up to collateralRatioBps.
     *      depositUSD = (ethPrice * msg.value) / 1e8
     *      minted = depositUSD * 10000 / collateralRatioBps
     */
    function depositAndMint() external payable nonReentrant {
        require(msg.value > 0, "No ETH sent");

        deposits[msg.sender] += msg.value;

        // 1) Convert user’s ETH deposit to a USD-like figure
        uint256 ethPrice = _getLatestEthPrice(); // e.g. 1800e8
        uint256 depositUSD = (ethPrice * msg.value) / 1e8; 
        // e.g. 1 ETH => depositUSD=1.8e21 => $1800 * 1e18 scale

        // 2) minted kUSD => depositUSD * (10000/collateralRatioBps)
        // e.g. ratio=150% => ratio=15000 => minted= depositUSD*(10000/15000)
        uint256 mintedAmount = (depositUSD * 10000) / collateralRatioBps;

        kokoroUSD.mint(msg.sender, mintedAmount);

        // If total vault balance >= 32, automatically restake
        if (address(this).balance >= RESTAKE_THRESHOLD) {
            _restake();
        }
    }

    /**
     * @dev Admin can manually restake if vault’s balance >= 32
     */
    function tryRestake() external onlyRole(ADMIN_ROLE) nonReentrant {
        require(address(this).balance >= RESTAKE_THRESHOLD, "Not enough to restake");
        _restake();
    }

    // Internal function that sends exactly 32 ETH for restaking
    function _restake() internal {
        (bool success, ) = restakeEOA.call{value: RESTAKE_THRESHOLD}("");
        require(success, "Transfer to restake EOA failed");
    }

    /**
     * @dev Liquidate if ratio < liquidationThresholdBps:
     *      1) forcibly burn user’s kUSD
     *      2) transfer user’s ETH to liquidator
     */
    function liquidate(address user) external nonReentrant {
        // Must be below threshold to liquidate
        uint256 ratioBps = _getUserCollateralRatioBps(user);
        require(ratioBps < liquidationThresholdBps, "Position is healthy");

        uint256 userDebt = kokoroUSD.balanceOf(user);
        require(userDebt > 0, "User has no debt");

        // user must have approved the vault to transfer their kUSD
        kokoroUSD.transferFrom(user, address(this), userDebt);
        kokoroUSD.burn(userDebt);

        // Transfer user’s ETH to liquidator
        uint256 userETH = deposits[user];
        deposits[user] = 0;

        (bool success, ) = msg.sender.call{value: userETH}("");
        require(success, "ETH transfer to liquidator failed");
    }

    /**
     * @dev Calculate user’s collateral ratio in basis points:
     *      depositUSD = (price * userETH) / 1e8
     *      ratio = depositUSD * 10000 / userDebt
     *      Because userDebt is in 1e18 decimals, depositUSD is also ~1e21 scale,
     *      so the ratio is dimensionless.
     */
    function _getUserCollateralRatioBps(address user) internal view returns (uint256) {
        uint256 userETH = deposits[user];
        if (userETH == 0) return 0; // no collateral

        uint256 ethPrice = _getLatestEthPrice();
        uint256 depositUSD = (ethPrice * userETH) / 1e8;

        uint256 userDebt = kokoroUSD.balanceOf(user);
        if (userDebt == 0) {
            return type(uint256).max; // no debt => infinite ratio
        }

        // ratioBps = depositUSD*10000 / userDebt
        return (depositUSD * 10000) / userDebt;
    }

    function _getLatestEthPrice() internal view returns (uint256) {
        (, int256 answer,,,) = priceFeed.latestRoundData();
        require(answer > 0, "Invalid price");
        return uint256(answer); // e.g. 1800e8 => $1800
    }

    receive() external payable {}
}
