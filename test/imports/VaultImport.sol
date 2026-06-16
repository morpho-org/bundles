// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.28;
// Force foundry to compile Vault V2 (and the Morpho Market V1 adapter) without importing them in the tests.

import {VaultV2Factory} from "../../lib/vault-v2/src/VaultV2Factory.sol";
import {MorphoMarketV1AdapterV2Factory} from "../../lib/vault-v2/src/adapters/MorphoMarketV1AdapterV2Factory.sol";
