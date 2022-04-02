// SPDX-License-Identifier: MIT
pragma solidity >=0.8.7 <0.9.0;

import "ds-test/test.sol";
import "./mocks/MockV3Aggregator.sol";
import "./mocks/MockERC20.sol";
import "../DaiEthOptions.sol";

contract DaiEthOptionsTest is DSTest {
    DaiEthOptions internal options;
    MockERC20 internal dai;
    address writer;
    address buyer;

    function setUp() public {
        dai = new MockERC20("DAI COIN", "DAI");
        options = new DaiEthOptions(address(dai));
    }

    function testWriteCallOption() public {
        assertTrue(true);
    }
}
