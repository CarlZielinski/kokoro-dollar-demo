// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/KokoroUSD.sol";
import "../src/StakedKokoroUSD.sol";

/**
 * @dev Foundry test suite for StakedKokoroUSD contract.
 */
contract StakedKokoroTest is Test {
    // Contracts
    KokoroUSD public kUSD;
    StakedKokoroUSD public sKUSD;

    // Test users
    address alice = address(0xAAA1);
    address bob = address(0xBBB1);
    address admin = address(this); // We'll act as admin

    // Helper constants
    uint256 constant INITIAL_SUPPLY = 10_000_000 * 1e18; // 10 million kUSD for testing

    function setUp() public {
        ///////////////////////////
        // 1) Deploy kUSD (stablecoin)
        ///////////////////////////
        kUSD = new KokoroUSD(); 
        // By default, the constructor grants the test contract
        // DEFAULT_ADMIN_ROLE + MINTER_ROLE.

        ///////////////////////////
        // 2) Mint some kUSD to Alice & Bob for testing
        ///////////////////////////
        // So they have tokens to stake
        // We'll do it from the test contract which has MINTER_ROLE
        kUSD.mint(alice, 100_000 * 1e18);
        kUSD.mint(bob, 100_000 * 1e18);

        ///////////////////////////
        // 3) Deploy StakedKokoroUSD
        ///////////////////////////
        sKUSD = new StakedKokoroUSD(address(kUSD));
        // The constructor grants ADMIN_ROLE to the deployer => this test contract

        // If we wanted another address to be admin, we could do:
        // sKUSD.grantRole(sKUSD.ADMIN_ROLE(), someOtherAdmin);
    }

    /**
     * @dev Basic test: Single user stakes kUSD when no sKUSD supply => 1:1 ratio
     */
    function testSingleUserStake() public {
        // 1) Approve
        vm.startPrank(alice);
        kUSD.approve(address(sKUSD), 100_000 * 1e18);

        // 2) Stake 1000 kUSD
        sKUSD.stake(1000e18);

        // 3) Confirm sKUSD minted = 1000
        // Because if totalSupply==0 initially, ratio=1:1
        assertEq(sKUSD.balanceOf(alice), 1000e18, "Alice's sKUSD mismatch");
        vm.stopPrank();

        // 4) Check the contract’s kUSD balance is 1000
        assertEq(kUSD.balanceOf(address(sKUSD)), 1000e18, "Contract didn't get 1000 kUSD");
    }

    /**
     * @dev Another user stakes afterwards => ensure ratio logic works
     */
    function testMultipleStakers() public {
        // Alice stakes first
        vm.startPrank(alice);
        kUSD.approve(address(sKUSD), 1_000_000e18);
        sKUSD.stake(1000e18);
        vm.stopPrank();

        // totalUnderlying = 1000
        // totalShares = 1000
        // ratio = 1:1

        // Now Bob stakes 2000 kUSD
        vm.startPrank(bob);
        kUSD.approve(address(sKUSD), 1_000_000e18);
        sKUSD.stake(2000e18);
        vm.stopPrank();

        // totalUnderlying => 3000 kUSD
        // totalShares => 1000 + mintedForBob
        // mintedForBob => 2000 * 1000 / 1000= 2000 sKUSD
        // So final totalShares=3000
        // Bob should have 2000 sKUSD

        assertEq(sKUSD.balanceOf(bob), 2000e18, "Bob's sKUSD mismatch");
        // total supply=3000
        assertEq(sKUSD.totalSupply(), 3000e18, "Final total supply mismatch");
        // Contract’s kUSD=3000
        assertEq(kUSD.balanceOf(address(sKUSD)), 3000e18, "Contract kUSD mismatch");
    }

    /**
     * @dev Admin simulates yield by depositing extra kUSD. 
     *      Then a user unstakes to see if they get more kUSD than they staked.
     */
    function testDistributeYieldAndUnstake() public {
        // 1) Alice stakes 1000 kUSD => gets 1000 sKUSD
        vm.startPrank(alice);
        kUSD.approve(address(sKUSD), 2000e18);
        sKUSD.stake(1000e18);
        vm.stopPrank();

        assertEq(sKUSD.balanceOf(alice), 1000e18, "Alice didn't get correct sKUSD");
        assertEq(kUSD.balanceOf(address(sKUSD)), 1000e18, "Contract kUSD mismatch after stake");

        // 2) Admin injects yield => 500 kUSD
        // We do sKUSD.distributeYield(500 kUSD)
        // First ensure we have enough minted for the admin
        kUSD.mint(admin, 1000e18); // give admin some tokens
        kUSD.approve(address(sKUSD), 500e18); // admin must approve
        sKUSD.distributeYield(500e18);

        // Now contract has 1500 kUSD total, total sKUSD=1000
        // => ratio is 1.5 : 1

        // 3) Alice unstakes all 1000 sKUSD => should get 1500 kUSD
        vm.startPrank(alice);
        sKUSD.unstake(1000e18);
        vm.stopPrank();

        // She should get 1500
        // Check final kUSD balance of Alice
        // She had minted 100k at setUp, staked 1000 => 99k left
        // Now she unstakes => +1500 => total 100,500 kUSD
        uint256 aliceBal = kUSD.balanceOf(alice);
        assertEq(aliceBal, 100_500e18, "Alice didn't receive the correct yield");

        // sKUSD totalSupply => 0
        assertEq(sKUSD.totalSupply(), 0, "sKUSD supply mismatch after full unstake");
        // Contract's kUSD => 0
        assertEq(kUSD.balanceOf(address(sKUSD)), 0, "Contract still holding kUSD?");
    }

    /**
     * @dev Non-admin tries to call distributeYield => should revert
     */
    function testRevert_DistributeYieldNotAdmin() public {
        // Bob tries to call distributeYield
        // He must have minted some tokens to do so
        // We'll let bob have some tokens:
        vm.startPrank(bob);
        kUSD.approve(address(sKUSD), 100e18);
        vm.expectRevert(); // AccessControl: missing role
        sKUSD.distributeYield(100e18);
        vm.stopPrank();
    }

    /**
     * @dev test unstaking partial and ensuring ratio math is correct
     */
    function testPartialUnstake() public {
        // 1) Alice stakes 1000 => 1000 sKUSD
        vm.startPrank(alice);
        kUSD.approve(address(sKUSD), 2000e18);
        sKUSD.stake(1000e18);
        vm.stopPrank();

        // 2) Admin yields 1000 => now contract has 2000 total, supply=1000 => ratio=2:1
        kUSD.mint(admin, 1000e18);
        kUSD.approve(address(sKUSD), 1000e18);
        sKUSD.distributeYield(1000e18);

        // 3) Alice unstakes half her sKUSD => 500 => expects 1000 kUSD
        // ratio= 2 => for 1 share => 2 kUSD
        vm.startPrank(alice);
        sKUSD.unstake(500e18);
        vm.stopPrank();

        // She receives 1000 kUSD
        // The contract still has 1000 kUSD left for her 500 shares
        // totalSupply= 500 => totalKUSD=1000 => ratio=2 => consistent

        assertEq(sKUSD.totalSupply(), 500e18, "Remaining supply mismatch");
        assertEq(kUSD.balanceOf(address(sKUSD)), 1000e18, "Contract's leftover mismatch");
    }
}
