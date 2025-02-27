// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/KokoroUSD.sol";
import "../src/KokoroVault.sol";
import "../src/AggregatorV3Interface.sol";

/**
 * @dev A minimal mock aggregator that simulates the Chainlink ETH/USD price feed.
 */
contract MockV3Aggregator is AggregatorV3Interface, Test {
    int256 public answer;
    uint8 public decimalsVal;

    constructor(uint8 _decimals, int256 _initialAnswer) {
        decimalsVal = _decimals;
        answer = _initialAnswer;
    }

    // ----------------------------------------
    // Mocked Chainlink aggregator functions
    // ----------------------------------------

    function decimals() external view override returns (uint8) {
        return decimalsVal;
    }

    function description() external pure override returns (string memory) {
        return "MockV3Aggregator";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80
    )
        external
        pure
        override
        returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        )
    {
        revert("Not implemented");
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        )
    {
        // Return roundId=0, answer, startedAt=0, updatedAt=0, answeredInRound=0
        return (0, answer, 0, 0, 0);
    }

    // Convenient helper to update the price
    function updateAnswer(int256 _answer) external {
        answer = _answer;
    }
}

/**
 * @title KokoroTest
 * @dev Foundry test suite for KokoroUSD and KokoroVault.
 */
contract KokoroTest is Test {
    // Contracts
    KokoroUSD public kokoroUSD;
    KokoroVault public kokoroVault;
    MockV3Aggregator public mockFeed;

    // Test users
    address alice = address(0xAAA1);
    address bob = address(0xBBB1);

    // Vault restake EOA (just a dummy address in tests)
    address restakeEOA = address(0x9999);

    // Helper constants
    uint8 constant CHAINLINK_DECIMALS = 8; // typical for ETH/USD
    int256 constant DEFAULT_ETH_PRICE = 1800e8; // $1800 with 8 decimals

    // Set up test environment
    function setUp() public {
        ///////////////////////////
        // 1. Deploy stablecoin
        ///////////////////////////
        kokoroUSD = new KokoroUSD();
        // By default, constructor grants:
        // - DEFAULT_ADMIN_ROLE to msg.sender (this test contract)
        // - MINTER_ROLE to msg.sender (this test contract)

        ///////////////////////////
        // 2. Deploy mock aggregator
        ///////////////////////////
        mockFeed = new MockV3Aggregator(CHAINLINK_DECIMALS, DEFAULT_ETH_PRICE);

        ///////////////////////////
        // 3. Deploy vault
        ///////////////////////////
        kokoroVault = new KokoroVault(
            address(kokoroUSD),
            restakeEOA,
            address(mockFeed)
        );
        // Vault constructor grants ADMIN_ROLE to msg.sender (this test contract)

        ///////////////////////////
        // 4. Grant MINTER_ROLE to the Vault in KokoroUSD
        ///////////////////////////
        // Without this, the vault can't mint.
        kokoroUSD.grantRole(kokoroUSD.MINTER_ROLE(), address(kokoroVault));
    }

    // ------------------------------------------------
    // Test: Basic deployment + roles
    // ------------------------------------------------
    function testDeploymentAndRoles() public {
        // The test contract (msg.sender) should have ADMIN_ROLE in vault
        bytes32 ADMIN_ROLE = kokoroVault.ADMIN_ROLE();
        assertTrue(kokoroVault.hasRole(ADMIN_ROLE, address(this)));

        // The vault should have MINTER_ROLE in the stablecoin
        bytes32 MINTER_ROLE = kokoroUSD.MINTER_ROLE();
        assertTrue(kokoroUSD.hasRole(MINTER_ROLE, address(kokoroVault)));
    }

    // ------------------------------------------------
    // Test: depositAndMint
    // ------------------------------------------------
    function testDepositAndMint() public {
        // Provide 10 ETH to Alice
        vm.deal(alice, 10 ether);

        // Check initial kUSD balance is zero
        assertEq(kokoroUSD.balanceOf(alice), 0);

        // The aggregator is returning $1800/ETH
        // depositAndMint => user deposit 1 ETH => $1800
        // With collateralRatioBps=15000 => 150% => user can borrow $1200 => 1200 * 1e18 tokens

        // Let Alice call depositAndMint with 1 ETH
        vm.startPrank(alice);
        kokoroVault.depositAndMint{value: 1 ether}();
        vm.stopPrank();

        // Check: does Alice have 1200 kUSD?
        uint256 expectedMint = 1200 * 1e18;
        assertEq(kokoroUSD.balanceOf(alice), expectedMint);

        // Vault accumulates 1 ETH from Alice
        assertEq(kokoroVault.deposits(alice), 1 ether);
    }

    // ------------------------------------------------
    // Test: Auto-restake at 32 ETH
    // ------------------------------------------------
    function testAutoRestake() public {
        // If total vault balance >= 32 ETH, it calls _restake automatically

        // Provide 100 ETH to Alice
        vm.deal(alice, 100 ether);

        // We'll track restakeEOA's balance
        uint256 beforeBalance = restakeEOA.balance;

        // depositAndMint with 32 ETH from Alice
        vm.prank(alice);
        kokoroVault.depositAndMint{value: 32 ether}();

        // The contract should have triggered `_restake()` automatically.
        // So restakeEOA should have gained 32 ETH
        uint256 afterBalance = restakeEOA.balance;
        assertEq(afterBalance - beforeBalance, 32 ether);

        // The vault's own balance is now 0, because it forwarded exactly 32 ETH.
        assertEq(address(kokoroVault).balance, 0);
    }

    // ------------------------------------------------
    // Test: Liquidation
    // ------------------------------------------------
    function testLiquidation() public {
        // 1. Provide 5 ETH to Bob => deposit => mints
        vm.deal(bob, 5 ether);

        vm.startPrank(bob);
        kokoroVault.depositAndMint{value: 5 ether}();
        vm.stopPrank();

        // Bob's deposit => 5 ETH => $9000 total at $1800/ETH
        // Collateral ratio=150% => minted = $9000*(10000/15000) = $6000 => 6000e18 tokens
        uint256 bobBalance = kokoroUSD.balanceOf(bob);
        uint256 expectedMint = 6000 * 1e18;
        assertEq(bobBalance, expectedMint);

        // 2. If price goes down, Bob might be under liquidation threshold
        // Let's set the aggregator price to $1200/ETH
        mockFeed.updateAnswer(1200e8);

        // Now Bob's 5 ETH is worth $6000 total
        // Bob minted $6000 => ratio = 100% => below liquidationThresholdBps=120%
        // He can be liquidated

        // 3. Liquidate Bob
        // We'll do the liquidation from 'alice' as the liquidator
        // First, Bob must have approved the vault to pull kUSD
        vm.prank(bob);
        kokoroUSD.approve(address(kokoroVault), type(uint256).max);

        // Now let's liquidate from Alice
        vm.prank(alice);
        kokoroVault.liquidate(bob);

        // Bob's deposit is reset to 0
        assertEq(kokoroVault.deposits(bob), 0);

        // Bob's kUSD should be 0
        assertEq(kokoroUSD.balanceOf(bob), 0);
    }


    function testRevert_WhenNoFundsToRestake() public {
        // No deposit
        vm.expectRevert("Not enough to restake");
        kokoroVault.tryRestake();
    }


    // ------------------------------------------------
    // Test: tryRestake() requires ADMIN_ROLE
    // ------------------------------------------------
    function testTryRestake() public {
        // 1) Give this contract 100 ETH
        vm.deal(address(this), 100 ether);

        // 2) This contract (msg.sender) deposits 33 ETH. We can do:
        kokoroVault.depositAndMint{value: 33 ether}();
        // Now the vault’s balance is 33 ETH (exceeds 32)...

        // 3) So calling tryRestake() won't revert
        kokoroVault.tryRestake();
    }


    /**
     * @dev Foundry no longer supports `testFail*`. Instead, we use vm.expectRevert().
     */
    function testRevert_WhenNotAdminCallsTryRestake() public {
        // Expect revert
        vm.expectRevert();

        // Impersonate alice (not an admin)
        vm.prank(alice);

        // This should revert because Alice lacks ADMIN_ROLE
        kokoroVault.tryRestake();
    }
}
