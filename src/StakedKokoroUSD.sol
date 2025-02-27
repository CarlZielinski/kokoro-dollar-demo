// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface IKokoroUSD {
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);

}

/**
 * @title StakedKokoroUSD
 * @notice This naive contract lets users stake their kUSD to receive sKUSD.
 *         The ratio of sKUSD to underlying kUSD can grow over time if the admin
 *         injects more kUSD via distributeYield (simulating earned restaking rewards).
 *
 *         For demonstration ONLY. Not production-ready.
 */
contract StakedKokoroUSD is ERC20, AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // The underlying stablecoin (kUSD)
    IKokoroUSD public immutable kokoroUSD;

    /**
     * @dev Constructor sets up roles and references the kUSD contract.
     */
    constructor(address _kUSD) ERC20("Staked Kokoro USD", "sKUSD") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        kokoroUSD = IKokoroUSD(_kUSD);
    }

    /**
     * @notice Stake `amount` of kUSD in exchange for sKUSD.
     * @param amount The quantity of kUSD to stake.
     */
    function stake(uint256 amount) external {
        require(amount > 0, "Cannot stake 0");

        // Track total underlying in the contract (before deposit)
        uint256 totalUnderlying = totalUnderlyingKUSD();
        // Total supply of sKUSD
        uint256 totalShares = totalSupply();

        // Transfer kUSD from user to this contract
        bool success = kokoroUSD.transferFrom(msg.sender, address(this), amount);
        require(success, "transferFrom failed");

        // If no sKUSD minted yet, mint 1:1
        if (totalShares == 0 || totalUnderlying == 0) {
            // Initially 1 sKUSD per 1 kUSD
            _mint(msg.sender, amount);
        } else {
            // mintedShares = amount * totalShares / totalUnderlying
            // This keeps the ratio consistent
            uint256 mintedShares = (amount * totalShares) / totalUnderlying;
            _mint(msg.sender, mintedShares);
        }
    }

    /**
     * @notice Unstake `shares` of sKUSD to get back kUSD plus your share of yield.
     * @param shares The amount of sKUSD to burn.
     */
    function unstake(uint256 shares) external {
        require(shares > 0, "Cannot unstake 0");
        uint256 totalShares = totalSupply();
        require(totalShares > 0, "No sKUSD minted");

        // The fraction of the underlying kUSD this user is entitled to
        // userUnderlying = shares * totalUnderlying / totalShares
        uint256 userUnderlying = (shares * totalUnderlyingKUSD()) / totalShares;

        // Burn user's sKUSD
        _burn(msg.sender, shares);

        // Transfer that many kUSD back to the user
        bool success = kokoroUSD.transfer(msg.sender, userUnderlying);
        require(success, "transfer failed");
    }

    /**
     * @notice Called by admin to add extra kUSD to the pool, simulating yield.
     * @dev This might represent actual restaking rewards in a real system.
     *      For now, we do a naive approach: admin calls `transferFrom` to deposit kUSD.
     * @param amount The additional kUSD to inject.
     */
    function distributeYield(uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(amount > 0, "Nothing to distribute");

        // Transfer kUSD from admin to this contract
        bool success = kokoroUSD.transferFrom(msg.sender, address(this), amount);
        require(success, "yield transferFrom failed");
    }

    /**
     * @notice The total kUSD currently held by this contract.
     */
    function totalUnderlyingKUSD() public view returns (uint256) {
        // The entire balance in kUSD
        // Some might come from user stakes, some from yield
        return _kUSDbalance();
    }

    /**
     * @dev Queries the contract's kUSD balance (underlying).
     */
    function _kUSDbalance() internal view returns (uint256) {
        // We assume all kUSD stored here is backing sKUSD
        // There's no “investment” outside the contract
        return IKokoroUSD(kokoroUSD).balanceOf(address(this));
    }
}
