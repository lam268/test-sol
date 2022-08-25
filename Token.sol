// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "./openzeppelin/ERC20.sol";
import "./openzeppelin/Ownable.sol";

contract Token is ERC20, Ownable {
    constructor() ERC20("Mochibits", "MCB") {
        _mint(msg.sender, 0);
    }

    function mint(uint256 _totalSupply) public onlyOwner {
        _mint(msg.sender, _totalSupply);
    }
}
