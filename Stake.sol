// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;
import "./openzeppelin/IERC20.sol";
import "./openzeppelin/Ownable.sol";
import "./openzeppelin/ReentrancyGuard.sol";

contract StakingContract is ReentrancyGuard, Ownable {
    // Address of vc token, need to change after deploy
    IERC20 public immutable vcTokenAddress;

    // A struct that holding staking information
    struct Staker {
        // Amount in VC_TOKEN
        uint256 stakedAmount;
        // Block time of the last staked action
        uint256 modifiedAt;
    }

    // List of stakers
    mapping(address => Staker) public stakers;

    // The lockingTime that user can not unstake
    uint256 public lockingTime = 90 days;

    // Token tier settings requiredTierAmounts[i] is the required amount of VC Token for a tier i
    //   This array is increasing by default, for example: [0, 1000, 2000, 3000]
    // uint256[] public requiredTierAmounts = [0, 10000, 20000, 50000, 100000];
    uint256[] public requiredTierAmounts = [0, 5000 * (10**18), 10000 * (10**18), 20000 * (10**18)];

    // Event staking and unstaking
    event Unstaking(address _stakerAddress, uint256 _amount);
    event Staking(address _stakerAddress, uint256 _amount);

    constructor(IERC20 _vcTokenAddress) {
        vcTokenAddress = _vcTokenAddress;
    }

    /**
     * @dev Function to update titan tier amount token.
     */
    function setTierAmount(uint256[] memory _tierAmounts) public onlyOwner {
        requiredTierAmounts = _tierAmounts;
    }

    /**
     * @dev Function to get investor tier.
     */
    function getTierOf(address _investorAddr) public view returns (uint) {
        for (uint256 index = requiredTierAmounts.length - 1; index >= 0; index--) {
            if (stakers[_investorAddr].stakedAmount >= requiredTierAmounts[index]) {
                return index;
            }
        }
        return 0;
    }

    /**
     * @dev Function for investors to stake tokens
     * @param _amount uint256 The address which owns the funds.
     */
    function stake(uint256 _amount) public nonReentrant {
        require(
            _amount > 0,
            "Invalid"
        );
        stakers[msg.sender].stakedAmount += _amount;
        // solhint-disable-next-line not-rely-on-time
        stakers[msg.sender].modifiedAt += block.timestamp;
        vcTokenAddress.transferFrom(msg.sender, address(this), _amount);
        emit Staking(msg.sender, _amount);
    }

    /**
     * @dev Function for investors to unstaking tokens
     */
    function unStake() public nonReentrant {
        require(stakers[msg.sender].stakedAmount > 0, "Invalid");
        // solhint-disable-next-line not-rely-on-time
        require(block.timestamp > stakers[msg.sender].modifiedAt + lockingTime, "Too soon");
        vcTokenAddress.transfer(msg.sender, stakers[msg.sender].stakedAmount);
        emit Unstaking(msg.sender, stakers[msg.sender].stakedAmount);
        delete stakers[msg.sender];
    }
}
