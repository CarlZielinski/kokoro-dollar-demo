// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

/**
 * @title KokoroUSD
 * @dev Minimal example of a stablecoin that the KokoroVault can mint.
 */
contract KokoroUSD is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor() ERC20("Kokoro USD", "kUSD") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    /**
     * @dev Allows contract(s) with MINTER_ROLE to mint kUSD.
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}