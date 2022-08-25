// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;
import "./openzeppelin/IERC20.sol";
import "./openzeppelin/Ownable.sol";
import "./openzeppelin/ReentrancyGuard.sol";
import "./Stake.sol";

/*
    The terminology that we use in this contract so far
        Raising: The process of collecting investments from people (investors)
        Payout: The process of rewarding investors with the expecting new token from a project
        VC: The one who provides the raising service to investor and then payout the token to investor.
        Investing: The act of delegating your raisingToken in exchange for payoutToken
        Tier: Each investor has a tier depend on how much they commit on the VC token
*/
contract ProjectContract is Ownable, ReentrancyGuard {
    // This is the token that we take invest in, it should be BUSD/USDT/USDC...
    IERC20 public raisingTokenAddress;

    // This is the token we will get from project, it is usually not set at the time
    //   of initialization. After TGE it will be released and we will set the project token
    IERC20 public payoutTokenAddress;

    // Must update before deployment
    StakingContract public immutable vcStakingAddress;

    // Metadata of project
    struct ProjectInfo {
        // Minimum raisingAmount
        //   If raising amount when the event closes is less than this, all invested assets will be refunded
        uint256 minRaisingAmount;
        // Maximum raisingAmount
        //   Can not raise more than maxRaisingAmount
        //   But maxRaisingAmount can be change
        uint256 maxRaisingAmount;
        // Minimum investment amount is based on tier
        //   minInvestmentAmounts[tier] is the maximum to a tier
        uint256[] minInvestmentAmounts;
        // Maximum investment amount is based on tier
        //   maxInvestmentAmounts[tier] is the maximum to a tier
        uint256[] maxInvestmentAmounts;
        // Project ID, all project metadata can be get from https://mochibit.vn/{projectId}.json
        uint64 projectId;
        // Unchangable sha256 of the project.json, to verify that once project is created, there is no way to alter the data
        //   like: projectURL, metadataURL...
        bytes projectSha256;
        // Address of the project, who collect the investment and then payout the reward token, immutable after created
        address projectAddress;
        // VC address, immutable after created
        address operatorAddress;
        // day start investment 
        uint256 startRaiseAt;
        // day end investment
        uint256 endRaiseAt;
    }

    // The total raisingToken has been invested by all investors
    uint256 public totalRaisedAmount;

    // The raisedTokenBalance
    uint256 public raisedTokenBalance;

    ProjectInfo public projectInfo;

    // investedAmount[address] is the invested amount in raisingToken of the investor ad [address]
    mapping(address => uint256) private investedAmount;

    // This is the list of amount of token released by the owner of the project
    //   For example, [10000, 20000] means that there are two releases with 10000 and 20000 each
    uint256[] public payoutTokenReleases;

    // claimedIndex[address] show which release index of the payoutTokenReleases the user of [address] can claim
    mapping(address => uint256) private claimedIndex;

    // State of the project
    enum ProjectState {
        // This is initial project state, when newly deployed, can not do anything
        PREPARING,
        // Project started accepting investment, can invest, no claiming, no refund
        ACCEPTING_INVESTMENT,
        // Project can pause accepting investment, no invest, no claiming, no refund
        PAUSE_INVESTMENT,
        // Awaiting token distribution, do not take investment, do not accept token claiming
        AWAIT_TOKEN_DISTRIBUTION,
        // Accepting token claiming, no investment, no refund
        ACCEPTING_TOKEN_CLAIM,
        // Has been cancel, no investment, no claiming, no refund
        CANCELLED_AWAITING_REFUND,
        // Accepting refund
        CANCELLED_ACCEPTING_REFUND,
        // Project closed, no more future action, operator can transfer the fee left in the contract
        CLOSED
    }

    ProjectState public projectState = ProjectState.PREPARING;

    mapping(ProjectState => mapping(ProjectState => uint8)) private stateTransitions;

    event NewInvestment(address _investorAddress, uint256 _amount);

    event ClaimingToken(address _investorAddress, uint256 _amount);

    /**
     * @dev Initializes the contract setting project infomation.
     */
    constructor(
        IERC20 _raisingTokenAddress,
        uint256 _minRaisingAmount,
        uint256 _maxRaisingAmount,
        uint256[] memory _minInvestmentAmounts,
        uint256[] memory _maxInvestmentAmounts,
        uint64 _projectId,
        bytes memory _projectSha256,
        address _projectAddress,
        address _operatorAddress,
        StakingContract _vcStakingContract
    ) {
        raisingTokenAddress = _raisingTokenAddress;
        projectInfo.minRaisingAmount = _minRaisingAmount;
        projectInfo.maxRaisingAmount = _maxRaisingAmount;
        projectInfo.minInvestmentAmounts = _minInvestmentAmounts;
        projectInfo.maxInvestmentAmounts = _maxInvestmentAmounts;
        projectInfo.projectId = _projectId;
        projectInfo.projectSha256 = _projectSha256;
        projectInfo.projectAddress = _projectAddress;
        projectInfo.operatorAddress = _operatorAddress;
        vcStakingAddress = _vcStakingContract;

        // Initialize the transition map
        stateTransitions[ProjectState.PREPARING][
            ProjectState.ACCEPTING_INVESTMENT
        ] = 1;
        // Project has problem, close
        stateTransitions[ProjectState.PREPARING][ProjectState.CLOSED] = 1;
        // Normal flow, fully invested, pending to wait for sending tokens to project
        // Cancel flow, not fully invested, pending to change raising token amount or refund
        stateTransitions[ProjectState.ACCEPTING_INVESTMENT][
            ProjectState.PAUSE_INVESTMENT
        ] = 1;
        // Normal flow, fully invested, sent token to project, pending to wait token distribution starts
        stateTransitions[ProjectState.PAUSE_INVESTMENT][ProjectState.AWAIT_TOKEN_DISTRIBUTION] = 1;
        // Normal flow, when project raise number of tokens invest, continue to accepting token
        stateTransitions[ProjectState.PAUSE_INVESTMENT][ProjectState.ACCEPTING_INVESTMENT] = 1;
        // Cancel flow, not sent raising token to project, need cancel
        stateTransitions[ProjectState.PAUSE_INVESTMENT][
            ProjectState.CANCELLED_AWAITING_REFUND
        ] = 1;
        // Normal flow token distributed, waiting for token claim
        stateTransitions[ProjectState.AWAIT_TOKEN_DISTRIBUTION][
            ProjectState.ACCEPTING_TOKEN_CLAIM
        ] = 1;
        // Cancel flow, incase project can not release or another party buy out our quota
        stateTransitions[ProjectState.AWAIT_TOKEN_DISTRIBUTION][
            ProjectState.CANCELLED_AWAITING_REFUND
        ] = 1;
        // Normal flow, after claiming all token, close this project
        stateTransitions[ProjectState.ACCEPTING_TOKEN_CLAIM][
            ProjectState.CLOSED
        ] = 1;
        // Normal flow, after confirm, allow refund process
        stateTransitions[ProjectState.CANCELLED_AWAITING_REFUND][
            ProjectState.CANCELLED_ACCEPTING_REFUND
        ] = 1;
        // Normal flow, close after all refunded
        stateTransitions[ProjectState.CANCELLED_ACCEPTING_REFUND][
            ProjectState.CLOSED
        ] = 1;
    }

    /**
     * Set the raising amount, happen when the investment went out or projects change raising amount
     */
    function setRaisingAmount(uint256 _minAmount, uint256 _maxAmount)
        public
        onlyOwner
    {
        require(_maxAmount >= _minAmount, "Error in set amount");
        require(projectState == ProjectState.PAUSE_INVESTMENT, "Error in set amount");
        projectInfo.minRaisingAmount = _minAmount;
        projectInfo.maxRaisingAmount = _maxAmount;
    }

    /**
     * Set the investment amount, happen when the investment went out unexpected
     * Just incase of emergency, because changing this affect all previous investments
     */
    function setInvestmentAmount(
        uint256[] memory _minAmounts,
        uint256[] memory _maxAmounts
    ) public onlyOwner {
        projectInfo.minInvestmentAmounts = _minAmounts;
        projectInfo.maxInvestmentAmounts = _maxAmounts;
    }

    /**
     * Set the startRaiseAt, endRaiseAt, happen when init project
     * happen when the project and vc change the start,end date
     */
    function setDueDate(
        uint256 _startRaiseAt,
        uint256 _endRaiseAt
    ) public onlyOwner {
        require(projectState == ProjectState.PREPARING || projectState == ProjectState.PAUSE_INVESTMENT, "Invalid state");
        projectInfo.startRaiseAt = _startRaiseAt;
        projectInfo.endRaiseAt = _endRaiseAt;
    }

    /**
     * @dev Funcrion to return minInvestmentAmounts
     * @return uint256[] minInvestmentAmounts
     */
    function getMinInvestmentAmounts() public view returns (uint256[] memory) {
        return projectInfo.minInvestmentAmounts;
    }

    /**
     * @dev Funcrion to return maxInvestmentAmounts
     * @return uint256[] maxInvestmentAmounts
     */
    function getMaxInvestmentAmounts() public view returns (uint256[] memory) {
        return projectInfo.maxInvestmentAmounts;
    }

    /**
     * payoutToken address is set when ready
     */
    function setPayoutToken(IERC20 _payoutTokenAddress) public onlyOwner {
        payoutTokenAddress = _payoutTokenAddress;
    }

    /**
     * Require new state has to follow state transition
     */
    function setProjectState(ProjectState _newState) public onlyOwner {
        require(stateTransitions[projectState][_newState] == 1, "Invalid");
        require(projectInfo.startRaiseAt != 0 && projectInfo.endRaiseAt != 0, "Invalid date");

        if (_newState == ProjectState.ACCEPTING_INVESTMENT && projectState == ProjectState.PREPARING ||
            _newState == ProjectState.ACCEPTING_INVESTMENT && projectState == ProjectState.PAUSE_INVESTMENT 
        ) {
            require(
                block.timestamp < projectInfo.endRaiseAt, "Can't change state this time"
            );
        }
        // When change to AWAIT_TOKEN_DISTRIBUTION, make sure that we meet the raising target
        if (_newState == ProjectState.AWAIT_TOKEN_DISTRIBUTION) {
            require(
                totalRaisedAmount > projectInfo.minRaisingAmount,
                "Invalid"
            );
            raisedTokenBalance = totalRaisedAmount;
        }

        // Owner have to spend all raising token in this contract before moving to token claim
        //   Otherwise this AWAIT_TOKEN_DISTRIBUTION state is a no-going-back, and owner can not
        //   Spend the fund anymore
        // Also, owner need to set the address of payoutToken before accepting payout claim
        if (
            projectState == ProjectState.AWAIT_TOKEN_DISTRIBUTION &&
            _newState == ProjectState.ACCEPTING_TOKEN_CLAIM
        ) {
            require(raisedTokenBalance == 0, "Token left");
            require(projectInfo.endRaiseAt > block.timestamp, "Invalid Date"); 
            require(address(payoutTokenAddress) != address(0x0), "Set payout");
        }
        projectState = _newState;
    }

    /**
     * @dev Function to get invested amount token.
     * @param _investorAddress The address of investor.
     * @return amount uint256 The amount of invested amount
     */
    function getInvestedAmountOf(address _investorAddress)
        public
        view
        returns (uint256)
    {
        return investedAmount[_investorAddress];
    }

    /**
     * The the index of claimed payout
     */
    function getClaimedIndexOf(address _investorAddress)
        public
        view
        returns (uint256)
    {
        return claimedIndex[_investorAddress];
    }

    /**
     * Return the total released token from an index
     *   Example: payoutTokenReleases = [1000, 2000, 3000]
     *      getTotalReleasedTokenFromIndex(0) = 1000 + 2000 + 3000 = 6000
     *      getTotalReleasedTokenFromIndex(1) = 2000 + 3000 = 5000
     *      getTotalReleasedTokenFromIndex(2) = 3000
     *      getTotalReleasedTokenFromIndex(3) = 0
     */
    function getTotalReleasedTokenFromIndex(uint256 _index)
        public
        view
        returns (uint256)
    {
        uint256 total = 0;
        for (uint256 i = _index; i < payoutTokenReleases.length; i++) {
            total += payoutTokenReleases[i];
        }
        return total;
    }

    /**
     * Get the total claimable payout token
     * @param _investorAddress The address of investor.
     * @return uint256 The amount of claimable amount
     */
    function getClaimablePayoutTokenFor(address _investorAddress)
        public
        view
        returns (uint256)
    {
        if (
            totalRaisedAmount == 0 ||
            projectState != ProjectState.ACCEPTING_TOKEN_CLAIM
        ) {
            return 0;
        }
        return (getTotalReleasedTokenFromIndex(claimedIndex[_investorAddress]) * investedAmount[_investorAddress]) / totalRaisedAmount;
    }

    /**
     * Add amount of PayoutToken released, remember that the token must be paidOut already to the contract address
     *   Before calling the function
     *   No going back if malfunction
     */
    function addPayoutRelease(uint256 _amount) public onlyOwner {
        require(projectState == ProjectState.ACCEPTING_TOKEN_CLAIM, "Invalid");
        payoutTokenReleases.push(_amount);
    }

    /**
     * @dev An investor can invest into the project with this function
     * @param _amount uint256 The amount of invested raisingToken
     */
    function invest(uint256 _amount) public nonReentrant {
        require(
            projectState == ProjectState.ACCEPTING_INVESTMENT,
            "Invalid State"
        );
        require(
            totalRaisedAmount + _amount <= projectInfo.maxRaisingAmount,
            "Fully invested"
        );
        uint256 tier = vcStakingAddress.getTierOf(msg.sender);
        require(
            _amount >= projectInfo.minInvestmentAmounts[tier],
            "Small Amount"
        );
        require(
            _amount <= projectInfo.maxInvestmentAmounts[tier],
            "Large Amount"
        );

        raisingTokenAddress.transferFrom(msg.sender, address(this), _amount);
        investedAmount[msg.sender] += _amount;
        totalRaisedAmount += _amount;

        emit NewInvestment(msg.sender, investedAmount[msg.sender]);
    }

    /**
     * @dev Function to for all investors to claim refund of raisingToken
     */
    function claimRefundToken() public nonReentrant {
        require(
            projectState == ProjectState.CANCELLED_ACCEPTING_REFUND,
            "Invalid"
        );
        // Do not need to check the refundAmount == 0 in contract, FE will do it
        // If ppl trigger this one themself, they pay for the gas
        uint256 refundAmount = investedAmount[msg.sender];
        investedAmount[msg.sender] = 0;
        raisingTokenAddress.transfer(msg.sender, refundAmount);
    }

    /**
     * @dev Function to distribute raised token the investment phase
     */
    function sendRaisedTokenToProject(uint256 _amount)
        public
        nonReentrant
        onlyOwner
    {
        require(
            projectState == ProjectState.AWAIT_TOKEN_DISTRIBUTION,
            "Invalid"
        );
        require(_amount <= raisedTokenBalance, "Not enough");
        raisedTokenBalance -= _amount;
        raisingTokenAddress.transfer(projectInfo.projectAddress, _amount);
    }

    /**
     * @dev Function to distribute raised token the investment phase
     */
    function sendRaisedTokenToOperator(uint256 _amount)
        public
        nonReentrant
        onlyOwner
    {
        require(
            projectState == ProjectState.AWAIT_TOKEN_DISTRIBUTION,
            "Invalid"
        );
        require(_amount <= raisedTokenBalance, "Not enough");
        raisedTokenBalance -= _amount;
        raisingTokenAddress.transfer(projectInfo.operatorAddress, _amount);
    }

    /**
     * @dev Function for investor to claim project token,
     * once you claim, you claim everything
     */
    function claimPayoutToken() public nonReentrant {
        require(projectState == ProjectState.ACCEPTING_TOKEN_CLAIM, "Invalid");
        uint256 claimableAmount = getClaimablePayoutTokenFor(msg.sender);
        require(claimableAmount > 0, "Nothing to claim");
        claimedIndex[msg.sender] = payoutTokenReleases.length;
        payoutTokenAddress.transfer(msg.sender, claimableAmount);
    }
}
