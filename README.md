# Option scalps 

Buyers get access to long or short positions for upto 1 hour by only paying option premium (<$10 for 1 eth for 15m @ $1600/ETH) and posting margin to set their liquidation price. Collateral is borrowed and used to purchase the base asset.

Writers have no downside since PNL is derived from base asset price appreciation/depreciation. Margin + liquidations cover possible shortfalls.

ERC-4626 LP tokens for LPs continously accruing quote assets with anytime withdrawals subject to available liquidity.

## Development

> (Optional) Setup the `.env` file with the vars mentioned in the `.env.sample` file.

### Compiling

```bash
yarn compile
```

### Running tests

Run all tests like this:

```bash
yarn test
```
