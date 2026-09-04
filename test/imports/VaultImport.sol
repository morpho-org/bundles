// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.28;
// Force foundry to compile Vault V2 (and the Morpho Market V1 adapter) without importing them in the tests.

// forge-lint: disable-next-item(unused-import) the import is what forces compilation.
import {VaultV2Factory} from "../../lib/vault-v2/src/VaultV2Factory.sol";
// forge-lint: disable-next-item(unused-import) the import is what forces compilation.
import {MorphoMarketV1AdapterV2Factory} from "../../lib/vault-v2/src/adapters/MorphoMarketV1AdapterV2Factory.sol";
// forge-lint: disable-next-item(unused-import) the import is what forces compilation.
import {WhitelistSendAssetsGate} from "../../lib/vault-v2/src/periphery/gates/WhitelistSendAssetsGate.sol";
// forge-lint: disable-next-item(unused-import) the import is what forces compilation.
import {BluePublicAllocator} from "../../lib/vault-v2/src/periphery/blue-public-allocator/BluePublicAllocator.sol";
