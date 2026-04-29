// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
//This combines multiple openzeppelin contracts into one since none support both minting and burning.
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
contract ERC20mb is ERC20, ERC20Burnable, Ownable {
    constructor(address initialOwner, string memory name, string memory symbol)
        ERC20(name, symbol)
    {
        _transferOwnership(initialOwner);
    }
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}