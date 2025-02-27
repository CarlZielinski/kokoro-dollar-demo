// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import "./KokoroUSD.sol";  // The stablecoin contract
import "./AggregatorV3Interface.sol"; // Chainlink interface

/**
 * @title KokoroVault
 * @dev This contract accepts ETH deposits, checks collateral,
 *      mints kUSD for the user, and can restake 32 ETH at a time.
 *      Uses OpenZeppelin v5 AccessControl for roles.
 */
contract KokoroVault is AccessControl {
    //////////////
    // Roles
    //////////////

    // Granting this role lets an address call `tryRestake`
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    //////////////
    // State
    //////////////

    // Mapping of user => total ETH deposited
    mapping(address => uint256) public deposits;

    // The stablecoin (KokoroUSD) instance
    KokoroUSD public kokoroUSD;

    // The address (EOA or contract) that triggers the restaking logic
    address public restakeEOA;

    // Chainlink price feed for ETH/USD on Sepolia (example: 0x694AA1769357215DE4FAC081bf1f309aDC325306)
    AggregatorV3Interface public priceFeed;

    // Collateral ratio in basis points (e.g., 150% => 15000)
    uint256 public collateralRatioBps = 15000;

    // Liquidation threshold in basis points (e.g., 120% => 12000)
    uint256 public liquidationThresholdBps = 12000;

    // Minimum batch size for restaking
    uint256 public constant RESTAKE_THRESHOLD = 32 ether;

    //////////////
    // Constructor
    //////////////

    /**
     * @param _kUSD Address of the KokoroUSD token
     * @param _restakeEOA The EOA (or contract) that runs off-chain code to restake in EigenLayer
     * @param _priceFeed Chainlink price feed for ETH/USD
     */
    constructor(address _kUSD, address _restakeEOA, address _priceFeed) {
        // Use the new AccessControl v5 pattern
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        kokoroUSD = KokoroUSD(_kUSD);
        restakeEOA = _restakeEOA;
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    //////////////
    // Deposits & Mint
    //////////////

    /**
     * @dev User deposits ETH and receives KokoroUSD (kUSD) immediately,
     *      according to the collateral ratio and current ETH price.
     */
    function depositAndMint() external payable {
    require(msg.value > 0, "No ETH sent");

    deposits[msg.sender] += msg.value;

    // 1) ETH price from Chainlink (8 decimals).
    uint256 ethPrice = _getLatestEthPrice(); // e.g., 1800e8
    // 2) Convert deposit to raw "USD * 1e18"
    uint256 depositUSD = (ethPrice * msg.value) / 1e8;
    // => for 1 ETH at $1800 => depositUSD=1.8e21 (that’s $1800 in 1e18 scale)

    // 3) minted = depositUSD * (10000 / collateralRatioBps)
    // e.g. ratio=15000 => minted= depositUSD * 10000 / 15000
    uint256 mintedAmount = (depositUSD * 10000) / collateralRatioBps;

    kokoroUSD.mint(msg.sender, mintedAmount);

    if (address(this).balance >= RESTAKE_THRESHOLD) {
        _restake();
    }
}

    //////////////
    // Liquidation
    //////////////

    /**
     * @dev Anyone can call `liquidate` on an undercollateralized user.
     *      This is highly simplified: we forcibly repay all their debt
     *      by burning the user's kUSD, then seize all their ETH.
     */
    function liquidate(address user) external {
        // Check ratio
        uint256 ratioBps = _getUserCollateralRatioBps(user);
        require(ratioBps < liquidationThresholdBps, "Position is healthy");

        // For simplicity, user’s entire kUSD balance is considered "debt"
        uint256 userDebt = kokoroUSD.balanceOf(user);
        require(userDebt > 0, "User has no debt");

        // (A) Pull kUSD from user => this contract
        // The user must have approved this contract to spend kUSD,
        // or you can require them to call `kUSD.transferFrom(...)` manually.
        kokoroUSD.transferFrom(user, address(this), userDebt);

        // (B) Burn that kUSD
        kokoroUSD.burn(userDebt);

        // (C) Seize user’s ETH
        uint256 userETH = deposits[user];
        deposits[user] = 0;

        // (D) Transfer to liquidator
        (bool success, ) = msg.sender.call{value: userETH}("");
        require(success, "ETH transfer failed");
    }

    /**
     * @notice Returns the user’s collateral ratio in BPS:
     *         (Collateral Value in USD / Debt in USD) * 100%
     */
    function _getUserCollateralRatioBps(address user) internal view returns (uint256) {
        uint256 userETH = deposits[user];
        if (userETH == 0) return 0; // no collateral => 0 ratio

        // Collateral (ETH) in USD
        uint256 ethPrice = _getLatestEthPrice(); 
        uint256 userDepositUSD = (ethPrice * userETH) / 1e8; // raw USD

        // Debt in kUSD
        uint256 userDebt = kokoroUSD.balanceOf(user);
        if (userDebt == 0) {
            // no debt => infinite ratio
            return type(uint256).max;
        }

        // Convert depositUSD to 1e18 scale
        uint256 depositUSD_1e18 = userDepositUSD * 1e18;

        // ratioBps = depositUSD_1e18 / userDebt * 10000
        uint256 ratioBps = (depositUSD_1e18 * 10000) / userDebt;
        return ratioBps;
    }

    //////////////
    // Restaking
    //////////////

    /**
     * @dev Admin can manually attempt restaking if the contract
     *      has at least 32 ETH. Protected by onlyRole(ADMIN_ROLE).
     */
    function tryRestake() external onlyRole(ADMIN_ROLE) {
        require(address(this).balance >= RESTAKE_THRESHOLD, "Not enough to restake");
        _restake();
    }

    /**
     * @dev Internal function that sends 32 ETH to restakeEOA
     */
    function _restake() internal {
        (bool success, ) = restakeEOA.call{value: RESTAKE_THRESHOLD}("");
        require(success, "Transfer to restake EOA failed");
    }

    //////////////
    // Utilities
    //////////////

    /**
     * @dev Reads the ETH/USD price from Chainlink aggregator,
     *      typically with 8 decimals for the feed.
     */
    function _getLatestEthPrice() internal view returns (uint256) {
        (, int256 answer,,,) = priceFeed.latestRoundData();
        require(answer > 0, "Invalid price");
        return uint256(answer); // e.g. 180000000000 => $1800 with 8 decimals
    }

    /**
     * @dev Accept ETH from anyone (e.g. in case restakeEOA returns leftover).
     */
    receive() external payable {}
}
