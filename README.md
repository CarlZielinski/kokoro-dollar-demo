# Kokoro Dollar 「心ドル」

**Tagline**: *“Kokoro Dollar: Return to the Heart of Crypto with Stablecoins that Earn Native Yield.”*

## Overview

**Kokoro Dollar / KokoroUSD** (kUSD) is a decentralized stablecoin prototype that aims to bring **trust-minimized**, **yield-bearing** functionality back to the core principles of crypto. While many popular stablecoins rely on fiat reserves (off-chain “Real World Assets”), KokoroUSD leans toward on-chain restaked Ethereum (via [EigenLayer](https://www.eigenlayer.xyz/) and [P2P.org](https://p2p.org/)), combined with AI agent infrastructure to manage user interactions.

> **Disclaimer**:  
> - This repository is a **hackathon** implementation. Some components (e.g., ephemeral EOA) are **not** trust-minimized.  
> - The code is **not** audited and is for demonstration only.

## Why Another Stablecoin?

- **Centralized Collateral**: Many stablecoins rely on off-chain entities holding real-world dollars.  
- **Trust Minimization**: KokoroUSD attempts to keep yield generation *on-chain* through **EigenLayer** restaking.  
- **Native Yield**: Instead of bridging fiat or requiring off-chain banks, we restake ETH to generate yield.  
- **AI Agents**: Provide a user-friendly interface (using Hyperbolic) that orchestrates deposits, staking, and yield behind the scenes.

## Project Components

1. **KokoroUSD** (`KokoroUSD.sol`)  
   - An ERC20 token representing the stablecoin.  
   - Has an `AccessControl`-based `MINTER_ROLE` that allows certain contracts (like the Vault) to create (mint) new kUSD.

2. **KokoroVault** (`KokoroVault.sol`)  
   - Collects ETH deposits.  
   - Mints kUSD (via `MINTER_ROLE`) for depositors.  
   - When 32 ETH accumulates, sends it to an EOA for restaking (hackathon approach).  
   - Also handles liquidation if collateral ratio is too low.

3. **StakedKokoroUSD** (`StakedKokoroUSD.sol`)  
   - Allows users to stake their kUSD and receive sKUSD.  
   - Admin can add yield to the contract, increasing the share price of sKUSD.

4. **Node.js Restake Bot** (`restake.js` and supporting files)  
   - Watches an EOA’s balance every minute.  
   - When it has ≥32 ETH, uses P2P’s API to restake, finalizing an on-chain deposit transaction.

### Why Do Certain Contracts Need `MINTER_ROLE`?

In **KokoroUSD**, only addresses with `MINTER_ROLE` can call `mint(...)` to create new tokens. This ensures that new kUSD can only be issued under controlled conditions, preventing unauthorized inflation. For example:

- **KokoroVault** must have `MINTER_ROLE` so it can create new kUSD when users deposit ETH.  
- **(Optional)** If you have other contracts or adapters that need to create kUSD, they too must be granted `MINTER_ROLE`.  
- By default, only the contract deployer (with `DEFAULT_ADMIN_ROLE`) can grant or revoke `MINTER_ROLE` from other addresses.

---

# Installation & Setup

1. **Clone Repository**

   ```bash
   git clone https://github.com/YourUser/kokoro-dollar-demo.git
   cd kokoro-dollar-demo
   ```

2. **Install Dependencies**

   - **Node & NPM**: For the restake bot scripts.  
   - **Foundry** (optional): For smart contract compilation & testing.

3. **Contracts**  
   - Source code is in `src/`: `KokoroUSD.sol`, `KokoroVault.sol`, `StakedKokoroUSD.sol`, aggregator interfaces, etc.

4. **Node.js Restake Bot**  
   - The `restake-bot/` folder includes: `package.json`, `config.json`, `restake.js`, `p2pApi.js`, `p2pSign.js`.

---

# Usage & Deployment

## 1. Compile & Deploy Contracts

1. **Compile** (using Foundry)
   ```bash
   forge build
   ```
   (Or use your preferred tool, e.g. Hardhat.)

2. **Deploy**  
   You can deploy with Foundry:
   ```bash
   forge create --rpc-url <URL> --private-key <PK> src/KokoroUSD.sol:KokoroUSD
   forge create --rpc-url <URL> --private-key <PK> src/KokoroVault.sol:KokoroVault \
        --constructor-args <kUSD_address> <restakeEOA> <chainlinkFeed>
   forge create --rpc-url <URL> --private-key <PK> src/StakedKokoroUSD.sol:StakedKokoroUSD \
        --constructor-args <kUSD_address>
   ```
   Adjust constructor arguments as needed.

3. **Grant the `MINTER_ROLE`**  
   - **KokoroVault** needs `MINTER_ROLE` in `KokoroUSD`. That means from your `kUSD` contract’s `DEFAULT_ADMIN_ROLE`, call:
     ```solidity
     kUSD.grantRole(kUSD.MINTER_ROLE(), vaultAddress);
     ```
   - If other components (like a bridging contract) need to mint kUSD, they also need `MINTER_ROLE`.  
   - This ensures only authorized issuers can create new tokens.

4. **Test**  
   ```bash
   forge test -vv
   ```
   This runs the entire suite (e.g., `KokoroTest.t.sol`, `StakedKokoroTest.t.sol`).

## 2. [Node.js Restake Bot](https://github.com/CarlZielinski/kokoro-restake-bot-demo)

1. **Configure**  
   Inside `restake-bot/` folder, create/edit `config.json`:
   ```json
   {
     "rpc": "https://sepolia.infura.io/v3/<YOUR_KEY>",
     "privateKey": "0xyourEphemeralEOAKey",
     "p2pApiUrl": "https://<p2pApiUrl>/",
     "authToken": "Bearer <p2pAuthToken>",
     "stakerAddress": "0xRestakeEOA",
     "feeRecipientAddress": "0xRestakeEOA",
     "controllerAddress": "0xRestakeEOA"
   }
   ```
   The ephemeral EOA is the address the vault’s `_restake()` function sends 32 ETH to.

2. **Install & Run**  
   ```bash
   cd restake-bot
   npm install
   node restake.js
   ```
   The script logs your EOA’s balance every 60 seconds, restaking each time there’s ≥32 ETH.  
   > **Security Note**: For a real deployment, do not store your private key in plain text; use environment variables or a secure vault.

---

# How It Works

1. **User -> Vault**: A user deposits ETH into the `KokoroVault`. Vault checks Chainlink price feed, mints kUSD to the user (due to its `MINTER_ROLE`).  
2. **Vault -> EOA**: Once total ETH in the vault hits 32, the vault calls `_restake()`, transferring 32 ETH to a designated ephemeral EOA.  
3. **Restake Bot**: The Node.js script sees ≥ 32 ETH in the EOA, calls P2P.org’s REST API to create a validator deposit.  
4. **Yield**: (Future) When yields come back from restaked ETH, we’d convert them to kUSD and call `StakedKokoroUSD.distributeYield()`, or deposit them directly into the vault.

---

# Limitations & Future Directions

1. **Trust Minimization**  
   - Currently, an EOA controls the 32 ETH restaking.  
   - In production, we’d use a multi-sig, MPC, or contract-based approach for direct restaking.

2. **Liquidations & Collateral**  
   - The vault code has simple liquidation logic—no partial auctions. Real stablecoins have more advanced designs.
   - In the future, we plan on having an AVS-based agent handle liquidations with priority access. This will be enforced via our own contracts and Uniswap V4 Hooks. 

3. **Yield Distribution**  
   - Real yield from restaked ETH is not fully integrated. For the hackathon, an admin function in `StakedKokoroUSD` simulates yield injection.

4. **Governance Token and Safety Module**
   - We plan on having a governance token ($KOKORO) that votes on protocol upgrades. Users will be able to stake their $KOKORO in two different ways.
   - We plan to integrate with Tally's Liquid Staked Governance protocol, which will allow users to stake their $KOKORO for $govKOKORO, which earns yield while allowing for voting power to be used.
   - We also plan to have a native $sKOKORO - users earn part of the yield the protocol achives via restaking. In exchange, staked KOKORO is used as collatoral for our safety module.
   - In case the protocol incurs bad debt, this collatoral can be used to make Kokoro Dollar whole again. 

---

**Join us** in returning to the heart of crypto: decentralized, on-chain stablecoin issuance backed by restaked ETH, with minimal trust assumptions—once we remove the ephemeral EOA and central injection. Questions or feedback? Feel free to contribute or open issues in this repository!
