// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.37;
// Force foundry to compile the Vault V2 Midnight adapter without importing it in the tests.

// forge-lint: disable-next-item(unused-import) the import is what forces compilation.
import {MidnightAdapterFactory} from "../../lib/vault-v2/src/adapters/midnight/MidnightAdapterFactory.sol";
