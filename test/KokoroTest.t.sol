// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/KokoroUSD.sol";
import "../src/KokoroVault.sol";
import "../src/AggregatorV3Interface.sol";

/**
 * @dev Minimal mock aggregator simulating Chainlink ETH/USD price feed (8 decimals).
 */
contract MockV3Aggregator is AggregatorV3Interface, Test {
    int256 public answer;
    uint8 public decimalsVal;

    constructor(uint8 _decimals, int256 _initialAnswer) {
        decimalsVal = _decimals;
        answer = _initialAnswer;
    }

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
        returns (uint80, int256, uint256, uint256, uint80)
    {
        revert("Not implemented");
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (0, answer, 0, 0, 0);
    }

    // Update the price for testing
    function updateAnswer(int256 _answer) external {
        answer = _answer;
    }
}

/**
 * @title KokoroTest
 * @dev Foundry test suite for the consistent scaling approach in KokoroVault.
 */
contract KokoroTest is Test {
    KokoroUSD public kokoroUSD;
    KokoroVault public kokoroVault;
    MockV3Aggregator public mockFeed;

    // Test addresses
    address alice = address(0xAAA1);
    address bob = address(0xBBB1);

    // EOA for restaking
    address restakeEOA = address(0x9999);

    // Price feed config
    uint8 constant CHAINLINK_DECIMALS = 8;
    int256 constant DEFAULT_ETH_PRICE = 1800e8; // $1800

    function setUp() public {
        // 1) Deploy stablecoin
        kokoroUSD = new KokoroUSD();
        // constructor => sets this test contract as DEFAULT_ADMIN_ROLE + MINTER_ROLE

        // 2) Deploy mock feed
        mockFeed = new MockV3Aggregator(CHAINLINK_DECIMALS, DEFAULT_ETH_PRICE);

        // 3) Deploy vault
        kokoroVault = new KokoroVault(
            address(kokoroUSD),
            restakeEOA,
            address(mockFeed)
        );

        // 4) Vault must have MINTER_ROLE in kUSD
        kokoroUSD.grantRole(kokoroUSD.MINTER_ROLE(), address(kokoroVault));
    }

    // ------------------------------------------------
    // Basic checks
    // ------------------------------------------------
    function testDeploymentAndRoles() public {
        // Vault’s ADMIN_ROLE => this test contract
        bytes32 ADMIN_ROLE = kokoroVault.ADMIN_ROLE();
        assertTrue(kokoroVault.hasRole(ADMIN_ROLE, address(this)));

        // Vault has MINTER_ROLE in the stablecoin
        bytes32 MINTER_ROLE = kokoroUSD.MINTER_ROLE();
        assertTrue(kokoroUSD.hasRole(MINTER_ROLE, address(kokoroVault)));
    }

    // ------------------------------------------------
    // depositAndMint => 1 ETH at $1800 => 1200 kUSD if ratio=150%
    // ------------------------------------------------
    function testDepositAndMint() public {
        // Give Alice 10 ETH
        vm.deal(alice, 10 ether);
        assertEq(kokoroUSD.balanceOf(alice), 0);

        // depositAndMint with 1 ETH
        vm.startPrank(alice);
        kokoroVault.depositAndMint{value: 1 ether}();
        vm.stopPrank();

        // At $1800 => depositUSD=1800*(1e18 scale) => minted=1200e18
        // Check minted => 1200 * 1e18 => 1.2e21
        uint256 expectedMint = 1200 * 1e18; 
        // Actual minted
        uint256 actual = kokoroUSD.balanceOf(alice);

        assertEq(
            actual,
            expectedMint,
            string.concat(
                "Mint mismatch: expected ",
                vm.toString(expectedMint),
                " got ",
                vm.toString(actual)
            )
        );

        // Vault accumulates 1 ETH from Alice
        assertEq(kokoroVault.deposits(alice), 1 ether);
    }

    // ------------------------------------------------
    // Auto-restake if deposit >= 32
    // ------------------------------------------------
    function testAutoRestake() public {
        // Provide 100 ETH to Alice
        vm.deal(alice, 100 ether);

        // Track restakeEOA’s balance
        uint256 beforeBalance = restakeEOA.balance;

        // depositAndMint with 32 ETH => triggers auto-restake
        vm.prank(alice);
        kokoroVault.depositAndMint{value: 32 ether}();

        uint256 afterBalance = restakeEOA.balance;
        // EOA got 32 ETH
        assertEq(afterBalance - beforeBalance, 32 ether);

        // Vault’s balance is 0
        assertEq(address(kokoroVault).balance, 0);
    }

    // ------------------------------------------------
    // Liquidation
    // ------------------------------------------------
    function testLiquidation() public {
        // Bob deposits 5 ETH => price=$1800 => depositUSD=9000 => minted=6000e18
        vm.deal(bob, 5 ether);
        vm.startPrank(bob);
        kokoroVault.depositAndMint{value: 5 ether}();
        vm.stopPrank();

        uint256 bobBal = kokoroUSD.balanceOf(bob);
        // 9000 => ratio=150% => minted=6000 => 6000e18
        uint256 expectedMint = 6000 * 1e18;
        assertEq(bobBal, expectedMint);

        // Drop price to $1200 => depositUSD=6000 => minted=6000 => ratio=6000/6000 => 100% <120%
        mockFeed.updateAnswer(1200e8);

        // Bob must approve the vault for liquidation to pull kUSD
        vm.prank(bob);
        kokoroUSD.approve(address(kokoroVault), type(uint256).max);

        // Liquidate from Alice
        vm.prank(alice);
        kokoroVault.liquidate(bob);

        // Now Bob's deposit=0, kUSD=0
        assertEq(kokoroVault.deposits(bob), 0);
        assertEq(kokoroUSD.balanceOf(bob), 0);
    }

    // ------------------------------------------------
    // testRevert_WhenNoFundsToRestake
    // ------------------------------------------------
    function testRevert_WhenNoFundsToRestake() public {
        vm.expectRevert("Not enough to restake");
        kokoroVault.tryRestake();
    }

    // ------------------------------------------------
    // testTryRestake with leftover
    // ------------------------------------------------
    function testTryRestake() public {
        // deposit 64 ETH => auto-restake triggers once for 32
        // leaves 32 ETH in vault
        vm.deal(address(this), 64 ether);
        kokoroVault.depositAndMint{value: 64 ether}();

        // Now we can manually restake the other 32
        kokoroVault.tryRestake();
    }
}
