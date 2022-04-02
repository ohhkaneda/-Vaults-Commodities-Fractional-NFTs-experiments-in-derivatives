// SPDX-License-Identifier: MIT
pragma solidity >=0.8.7 <0.9.0;

import "ds-test/test.sol";
import "./mocks/MockV3Aggregator.sol";
import "../PriceFeedServer.sol";

contract PriceFeedServerTest is DSTest {
    uint8 public constant DECIMALS = 18;
    int256 public constant INITIAL_ANSWER = 1e18;
    PriceFeedServer public priceFeedServer;
    MockV3Aggregator public mockV3Aggregator;

    function setUp() public {
        mockV3Aggregator = new MockV3Aggregator(DECIMALS, INITIAL_ANSWER);
        priceFeedServer = new PriceFeedServer(address(mockV3Aggregator));
    }

    function testGetPriceFeed() public {
        uint256 price = priceFeedServer.getPriceFeed();
        assertTrue(price * 1e18 == uint256(INITIAL_ANSWER));
    }
}
