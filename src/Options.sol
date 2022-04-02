// SPDX-License-Identifier: MIT
pragma solidity >=0.8.7 <0.9.0;

import "chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "solmate/utils/ReentrancyGuard.sol";
import "solmate/auth/Auth.sol";
import "solmate/tokens/ERC20.sol";

///@title DAI/ETH COVERED OPTIONS
///@author tobias
///@notice This Smart Contract allows for the buying/writing of Covered Calls & Cash-Secured Puts with ETH as the underlying.
/// Calls: Let you buy an asset at a set price on a specific date.
/// Puts: Let you sell an asset at a set price on a specific date.
/// Covered Call: The seller(writer) transfers ETH for collateral and writes a Covered Call. The buyer pays premium w DAI.
/// Covered Call: At expiration, the buyer has right to ETH at strike price if market price is greater than strike price. Settles with DAI.
/// Cash-Secured Put: The writer transfers ETH for collateral. Buyer pays premium w DAI.
/// Cash-Secured Put: At expiration, if market price less than strike, buyer has right to sell ETH at the strike. Settles w DAI.
/// All options have the following properties:
/// Strike price - The price at which the underlying asset can either be bought or sold.
/// Expiry - The date at which the option expires.
/// Premium - The price of the options contract.
///This smart contract supports two strategies for option writer:
///1. Covered Calls - You sell upside on an asset while you hold it for yield, which comes from premium (Netural/Bullish on asset).
///2. Cash-secured Puts - You earn yeild on cash (Bullish).

contract Options is ReentrancyGuard, Auth {
    AggregatorV3Interface internal daiEthPriceFeed;

    ERC20 dai;

    uint256 public optionCounter;

    mapping(address => address) public tokenToEthFeed;
    mapping(uint256 => Option) public optionIdToOption;
    mapping(address => uint256[]) public tradersPosition;

    enum OptionState {
        Open,
        Bought,
        Cancelled,
        Exercised
    }

    enum OptionType {
        Call,
        Put
    }

    struct Option {
        address writer;
        address buyer;
        uint256 amount;
        uint256 strike;
        uint256 premiumDue;
        uint256 expiration;
        uint256 collateral;
        OptionState optionState;
        OptionType optionType;
    }

    /**************/
    /* ERRORS */
    /*************/

    error TransferFailed();
    error NeedsMoreThanZero();
    error OptionNotValid(uint256 _optionId);

    /**************/
    /* EVENTS */
    /*************/

    event CallOptionOpen(
        address writer,
        uint256 amount,
        uint256 strike,
        uint256 premium,
        uint256 expiration,
        uint256 value
    );
    event PutOptionOpen(
        address writer,
        uint256 amount,
        uint256 strike,
        uint256 premium,
        uint256 expiration,
        uint256 value
    );
    event CallOptionBought(address buyer, uint256 id);
    event PutOptionBought(address buyer, uint256 id);
    event CallOptionExercised(address buyer, uint256 id);
    event PutOptionExercised(address buyer, uint256 id);
    event OptionExpiresWorthless(address buyer, uint256 Id);
    event FundsRetrieved(address writer, uint256 id, uint256 value);
    event AllowedTokenSet(address token, address priceFeed);

    /**************/
    /* CONSTRUCTOR */
    /*************/

    ///CHAINLINK PRICEFEEDS & DAI ADDRESSES FOR EASE OF USE
    ///NETWORK: KOVAN
    ///DAI/ETH Address: 0x22B58f1EbEDfCA50feF632bD73368b2FdA96D541
    ///Kovan DAI Addr: 0x4f96fe3b7a6cf9725f59d353f723c1bdb64ca6aa
    ///NETWORK: RINKEBY
    ///DAI/ETH Address: 0x74825DbC8BF76CC4e9494d0ecB210f676Efa001D
    ///Rinkeby DAI Addr: 0x4f96fe3b7a6cf9725f59d353f723c1bdb64ca6aa (faucet token)
    constructor(address _priceFeed, address _daiAddr) {
        daiEthPriceFeed = AggregatorV3Interface(_priceFeed);
        dai = ERC20(_daiAddr);
    }

    /**************************/
    /* CALL OPTION FUNCTIONS */
    /************************/

    function writeCallOption(
        uint256 _amount,
        uint256 _strike,
        uint256 _premiumDue,
        uint256 _daysToExpiry
    ) external payable moreThanZero(_amount, _strike, _premiumDue) {
        require(msg.value == _strike, "CALL: NO ETH COLLATERAL");

        optionIdToOption[optionCounter] = Option(
            msg.sender,
            address(0),
            _amount,
            _strike,
            _premiumDue,
            block.timestamp + _daysToExpiry,
            msg.value,
            OptionState.Open,
            OptionType.Call
        );

        tradersPosition[msg.sender].push(optionCounter);
        optionCounter++;

        emit CallOptionOpen(
            msg.sender,
            _amount,
            _strike,
            _premiumDue,
            block.timestamp + _daysToExpiry,
            msg.value
        );
    }

    function buyCallOption(uint256 _optionId)
        external
        optionExists(_optionId)
        isValidOpenOption(_optionId)
        nonReentrant
    {
        Option memory option = optionIdToOption[_optionId];

        require(option.optionType == OptionType.Call, "NOT A CALL");

        //buyer pays w dai
        bool paid = dai.transferFrom(
            msg.sender,
            address(this),
            option.premiumDue
        );
        if (!paid) revert TransferFailed();

        //dai transfered to writer
        dai.transfer(option.writer, option.premiumDue);

        optionIdToOption[_optionId].buyer = msg.sender;
        optionIdToOption[_optionId].optionState = OptionState.Bought;
        tradersPosition[msg.sender].push(_optionId);

        emit CallOptionBought(msg.sender, _optionId);
    }

    function exerciseCallOption(uint256 _optionId)
        external
        payable
        optionExists(_optionId)
        nonReentrant
    {
        Option memory option = optionIdToOption[_optionId];

        require(msg.sender == option.buyer, "NOT BUYER");
        require(option.optionState == OptionState.Bought, "NEVER BOUGHT");
        require(option.expiration > block.timestamp, "HAS NOT EXPIRED");

        uint256 marketPrice = option.amount * getPriceFeed();

        require(marketPrice > option.strike, "NOT GREATER THAN STRIKE");

        //buyer gets right to buy ETH at strike w DAI
        bool paid = dai.transferFrom(msg.sender, address(this), option.strike);
        if (!paid) revert TransferFailed();

        //transfer to msg.sender the writer's ETH collateral
        payable(msg.sender).transfer(option.collateral);

        //transfer dai to option writer
        dai.transfer(option.writer, option.strike);

        optionIdToOption[_optionId].optionState = OptionState.Exercised;

        emit CallOptionExercised(msg.sender, _optionId);
    }

    /**************************/
    /* PUT OPTION FUNCTIONS */
    /************************/

    function writePutOption(
        uint256 _amount,
        uint256 _strike,
        uint256 _premiumDue,
        uint256 _daysToExpiry
    ) external payable moreThanZero(_amount, _strike, _premiumDue) {
        require(msg.value == _strike, "PUT: NO ETH COLLATERAL");

        optionIdToOption[optionCounter] = Option(
            msg.sender,
            address(0),
            _amount,
            _strike,
            _premiumDue,
            block.timestamp + _daysToExpiry,
            msg.value,
            OptionState.Open,
            OptionType.Put
        );

        tradersPosition[msg.sender].push(optionCounter);
        optionCounter++;

        emit PutOptionOpen(
            msg.sender,
            _amount,
            _strike,
            _premiumDue,
            block.timestamp + _daysToExpiry,
            msg.value
        );
    }

    function buyPutOption(uint256 _optionId)
        external
        optionExists(_optionId)
        isValidOpenOption(_optionId)
        nonReentrant
    {
        Option memory option = optionIdToOption[_optionId];

        require(option.optionType == OptionType.Put, "NOT A PUT");

        //pay premium w dai
        bool paid = dai.transferFrom(
            msg.sender,
            address(this),
            option.premiumDue
        );
        if (!paid) revert TransferFailed();

        //transfer premium to writer
        dai.transfer(option.writer, option.premiumDue);

        optionIdToOption[_optionId].buyer = msg.sender;
        optionIdToOption[_optionId].optionState = OptionState.Bought;
        tradersPosition[msg.sender].push(_optionId);

        emit CallOptionBought(msg.sender, _optionId);
    }

    function exercisePutOption(uint256 _optionId)
        external
        payable
        optionExists(_optionId)
        nonReentrant
    {
        Option memory option = optionIdToOption[_optionId];

        require(msg.sender == option.buyer, "NOT BUYER");
        require(option.optionState == OptionState.Bought, "NEVER BOUGHT");
        require(option.expiration > block.timestamp, "HAS NOT EXPIRED");

        uint256 marketPrice = option.amount * getPriceFeed();

        require(marketPrice < option.strike, "NOT LESS THAN STRIKE");

        //buyer gets to sell ETH(gets collateral) for DAI at strike to option writer
        bool paid = dai.transferFrom(msg.sender, address(this), option.strike);
        if (!paid) revert TransferFailed();

        payable(msg.sender).transfer(option.collateral);

        //transfer dai to option writer
        dai.transfer(option.writer, option.strike);

        optionIdToOption[_optionId].optionState = OptionState.Exercised;

        emit PutOptionExercised(msg.sender, _optionId);
    }

    /**************************/
    /* EXTRA OPTION FUNCTIONS */
    /************************/

    function optionExpiresWorthless(uint256 _optionId)
        external
        optionExists(_optionId)
    {
        Option memory option = optionIdToOption[_optionId];

        require(option.optionState == OptionState.Bought, "NEVER BOUGHT");
        require(optionIdToOption[_optionId].buyer == msg.sender, "NOT BUYER");
        require(option.expiration > block.timestamp, "NOT EXPIRED");

        uint256 marketPrice = option.amount * getPriceFeed();

        if (option.optionType == OptionType.Call) {
            //For call, if market < strike, call options expire worthless
            require(marketPrice < option.strike, "PRICE NOT LESS THAN STRIKE");
            optionIdToOption[_optionId].optionState = OptionState.Cancelled;
        } else {
            //For put, if market > strike, put options expire worthless
            require(
                marketPrice > option.strike,
                "PRICE NOT GREATER THAN STRIKE"
            );
            optionIdToOption[_optionId].optionState = OptionState.Cancelled;
        }

        emit OptionExpiresWorthless(msg.sender, _optionId);
    }

    function retrieveExpiredFunds(uint256 _optionId) external nonReentrant {
        Option memory option = optionIdToOption[_optionId];

        require(option.optionState == OptionState.Cancelled);
        require(option.expiration < block.timestamp, "NOT EXPIRED");
        require(msg.sender == option.writer, "NOT WRITER");

        payable(msg.sender).transfer(option.collateral);

        emit FundsRetrieved(msg.sender, _optionId, option.collateral);
    }

    /*****************************/
    /* Owner Withdraw Functions */
    /****************************/

    function withdrawEth(address payable _to) public requiresAuth {
        (bool withdrawSuccess, ) = _to.call{value: address(this).balance}("");
        require(withdrawSuccess, "ETH WITHDRAW FAILED");
    }

    function withdrawDai(address payable _to) public requiresAuth {
        uint256 daiBalance = dai.balanceOf(address(this));
        (bool withdrawSuccess, ) = _to.call{value: daiBalance}("");
        require(withdrawSuccess, "DAI WITHDRAW FAILED");
    }

    /*********************************/
    /* Oracle (Chainlink) Functions */
    /*********************************/

    function getPriceFeed() public view returns (uint256) {
        (, int256 price, , , ) = daiEthPriceFeed.latestRoundData();
        return (uint256(price)) / 1e18;
    }

    /**************/
    /* Modifiers */
    /*************/

    modifier moreThanZero(
        uint256 amount,
        uint256 strikePrice,
        uint256 premiumCost
    ) {
        if (amount <= 0 || strikePrice <= 0 || premiumCost <= 0)
            revert NeedsMoreThanZero();
        _;
    }

    modifier optionExists(uint256 optionId) {
        if (optionIdToOption[optionId].writer == address(0))
            revert OptionNotValid(optionId);
        _;
    }

    modifier isValidOpenOption(uint256 optionId) {
        if (
            optionIdToOption[optionId].optionState != OptionState.Open ||
            optionIdToOption[optionId].expiration > block.timestamp
        ) revert OptionNotValid(optionId);
        _;
    }
}
