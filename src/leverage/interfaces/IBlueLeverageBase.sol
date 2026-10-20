// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

interface IBlueLeverageBase {
    /// ERRORS ///
    error DeadlinePassed();
    error IncompleteFill();
    error InvalidLeverage();
    error LtvExceeded();
    error UnauthorizedCallback();

    /// STORAGE GETTERS ///

    function BLUE() external view returns (address);
}
