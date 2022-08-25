// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;
import "./openzeppelin/Ownable.sol";
import "./Project.sol";
import "./openzeppelin/IERC20.sol";

contract ProjectFactory is Ownable {
    address[] public projectList;
    StakingContract public immutable vcStakingAddress;

    constructor(StakingContract _vcStakingAddress) {
        vcStakingAddress = _vcStakingAddress;
    }

    /**
     * @dev Function to get investor tier.
     * @return projectAddresses address[] memory created projects address list
     */
    function getProjectList() public view returns(address[] memory) {
        return projectList;
    }

    /**
     * Create a new project, will keep this for MVP
     */
    function createNewProject(
        IERC20 _raisingTokenAddress,
        uint256 _minRaisingAmount,
        uint256 _maxRaisingAmount,
        uint256[] memory _minInvestmentAmounts,
        uint256[] memory _maxInvestmentAmounts,
        uint64 _projectId,
        bytes memory _projectSha256,
        address _projectAddress,
        address _operatorAddress
    ) public onlyOwner returns (ProjectContract) {
        ProjectContract newProject = new ProjectContract(
            _raisingTokenAddress,
            _minRaisingAmount,
            _maxRaisingAmount,
            _minInvestmentAmounts,
            _maxInvestmentAmounts,
            _projectId,
            _projectSha256,
            _projectAddress,
            _operatorAddress,
            vcStakingAddress
        );
        projectList.push(address(newProject));
        return newProject;
    }
}
