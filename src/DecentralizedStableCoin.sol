// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/** 
* @title DecentralizedStableCoin
* @author Cedric Vogt
* Collateral: wETH, wBTC
* Minting: Algorithmic
* Relative Stability: Pegged to USD
*
* This is the contract meant to be governed by DSCEngine. This 
contract is just the ERC20 implementation of our stablecoin system.
*/
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__NotZeroAddress();

    // unlike standard ERC20 tokens, we need an Owner (ownable) so we can control our supply with controlled minting/burning when e.g. depeg etc.
    // standard erc20 tokens just have a fixed supply, no ongoing control and hence ownership needed
    constructor(address initial_owner) ERC20("DecentralizedStableCoin", "DSC") Ownable(initial_owner){
    }

    function burn(uint256 _amount) public override onlyOwner{ // could in our case be external, but then it would differ from the parent burn function that is public
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }

        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }

        super.burn(_amount); // use the burn function from the parent class (super class)
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__NotZeroAddress();
        }

        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        } 

        _mint(_to, _amount); // we are not overriding any _mint function, we are just using the one of our inherited contract -> no super is needed
        
        return true;
    }

}