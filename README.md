## Stablecoin Development

1. (Relative Stability): Anchored or Pegged -> $1.00
    1. Chainlink Price feed.
    2. Set a function to exchange ETH & VTC -> $$$
2. Stability Mechanism (Minting): Algorithmic (Decentralized)
    1. People can only mint the stablecoin with enough collateral (coded)
3. Collateral Type: Exogenous (We use Cryptocurrencies):
    1. wETH
    2. wBTC

- set health factor if debt is zero (if we havent minted anything we would divide by zero, not possible! account for that!)
- write more tests and debug my initial issue! 
- finish the rest
- repeat the fuzztest logic and how we figured out that we had a division by zero in the healthfactor calculation. it would show the real benefit of fuzztesting: also looking for edge cases that we didnt account for and potential bugs in our code logic (as we had in our division by zero when there is no dsc minted but collateral deposited and redeemed)

1. what are our invariants/properties?


