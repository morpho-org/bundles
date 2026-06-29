// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity >=0.5.0;

enum PermitKind {
    None,
    ERC2612,
    Permit2
}

struct TokenPermit {
    PermitKind kind;
    bytes data;
}
