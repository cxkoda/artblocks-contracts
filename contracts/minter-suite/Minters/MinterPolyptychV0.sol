// SPDX-License-Identifier: LGPL-3.0-only
// Created By: Art Blocks Inc.

import "../../interfaces/0.8.x/IGenArt721CoreContractV3_Engine.sol";
import "../../interfaces/0.8.x/IMinterFilterV0.sol";
import "../../interfaces/0.8.x/IFilteredMinterHolderV2.sol";
import "../../interfaces/0.8.x/IRandomizerPolyptychV0.sol";
import "../../interfaces/0.8.x/IDelegationRegistry.sol";
import "./MinterBase_v0_1_1.sol";

import "@openzeppelin-4.5/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin-4.5/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin-4.5/contracts/utils/structs/EnumerableSet.sol";

pragma solidity 0.8.17;

/**
 * @title Core contract interface for accessing the randomizer from the minter
 * @notice This interface provides the minter with access to the randomizer, allowing the
 * token hash seed for a newly-minted token to be assigned by the minter if the artist
 * has enabled the project as a polyptych. Polytptych projects must use the V3 engine
 * core contract, polyptych minter, and polyptych randomizer - this interface allows the
 * minter to access the randomizer.
 */
interface IGenArt721CoreContractV3WithRandomizer is
    IGenArt721CoreContractV3_Engine
{
    /// current randomizer contract
    function randomizerContract() external returns (IRandomizerPolyptychV0);
}

/**
 * @title Filtered Minter contract that allows tokens to be minted with ETH or ERC20 tokens
 * when purchaser owns an allowlisted ERC-721 NFT. This contract must be used with
 * an accompanying randomizer contract that is configured to copy the token hash seed
 * from the allowlisted token to a corresponding newly-minted token.
 * The source token may only be used to mint one additional polyptych "panel" if the token
 * has not yet been used to mint a panel with the currently configured panel ID. To add
 * an additional panel to a project, the panel ID may be incremented for the project
 * using the `incrementPolyptychProjectPanelId` function. Panel IDs for a project may only
 * be incremented such that panels must be minted in the order of their panel ID. Tokens
 * of the same project and panel ID may be minted in any order.
 * This is designed to be used with IGenArt721CoreContractV3_Engine contracts with an
 * active IPolyptychRandomizerV0 randomizer available for this minter to use.
 * This minter requires both a properly configured engine core contract and polyptych
 * randomizer in order to mint polyptych tokens.
 * @author Art Blocks Inc.
 * @notice Privileged Roles and Ownership:
 * This contract is designed to be managed, with limited powers.
 * Privileged roles and abilities are controlled by the core contract's Admin
 * ACL contract and a project's artist. Both of these roles hold extensive
 * power and can modify minter details.
 * Care must be taken to ensure that the admin ACL contract and artist
 * addresses are secure behind a multi-sig or other access control mechanism.
 * ----------------------------------------------------------------------------
 * The following functions are restricted to the core contract's Admin ACL
 * contract:
 * - registerNFTAddress
 * - unregisterNFTAddress
 * ----------------------------------------------------------------------------
 * The following functions are restricted to a project's artist:
 * - allowHoldersOfProjects
 * - removeHoldersOfProjects
 * - allowRemoveHoldersOfProjects
 * - updatePricePerTokenInWei
 * - updateProjectCurrencyInfo
 * - setProjectMaxInvocations
 * - manuallyLimitProjectMaxInvocations
 * ----------------------------------------------------------------------------
 * Additional admin and artist privileged roles may be described on other
 * contracts that this minter integrates with.
 * ----------------------------------------------------------------------------
 * This contract allows gated minting with support for vaults to delegate minting
 * privileges via an external delegation registry. This means a vault holding an
 * allowed token can delegate minting privileges to a wallet that is not holding an
 * allowed token, enabling the vault to remain air-gapped while still allowing minting.
 * The delegation registry contract is responsible for managing these delegations,
 * and is available at the address returned by the public immutable
 * `delegationRegistryAddress`. At the time of writing, the delegation
 * registry enables easy delegation configuring at https://delegate.cash/.
 * Art Blocks does not guarentee the security of the delegation registry, and
 * users should take care to ensure that the delegation registry is secure.
 * Delegations must be configured by the vault owner prior to purchase. Supported
 * delegation types include token-level, contract-level (via genArt721CoreAddress), or
 * wallet-level delegation. Contract-level delegations must be configured for the core
 * token contract as returned by the owned token's core contract address.
 */
contract MinterPolyptychV0 is
    ReentrancyGuard,
    MinterBase,
    IFilteredMinterHolderV2
{
    // add Enumerable Set methods
    using EnumerableSet for EnumerableSet.AddressSet;

    /// Delegation registry address
    address public immutable delegationRegistryAddress;

    /// Delegation registry address
    IDelegationRegistry private immutable delegationRegistryContract;

    /// Core contract address this minter interacts with
    address public immutable genArt721CoreAddress;

    /// This contract handles cores with interface IV3
    IGenArt721CoreContractV3WithRandomizer private immutable genArtCoreContract;

    /// Minter filter address this minter interacts with
    address public immutable minterFilterAddress;

    /// Minter filter this minter may interact with.
    IMinterFilterV0 private immutable minterFilter;

    // Stores whether a panel with an ID has been minted for a given token hash seed
    // panelId => hashSeed => panelIsMinted
    mapping(uint256 => mapping(bytes12 => bool))
        public polyptychPanelHashSeedIsMinted;

    /// minterType for this minter
    string public constant minterType = "MinterPolyptychV0";

    /// minter version for this minter
    string public constant minterVersion = "v0.1.0";

    uint256 constant ONE_MILLION = 1_000_000;

    struct ProjectConfig {
        bool maxHasBeenInvoked;
        bool priceIsConfigured;
        uint24 maxInvocations;
        uint24 polyptychPanelId;
        address currencyAddress;
        uint256 pricePerTokenInWei;
        string currencySymbol;
    }

    mapping(uint256 => ProjectConfig) public projectConfig;

    /// Set of core contracts allowed to be queried for token holders
    EnumerableSet.AddressSet private _registeredNFTAddresses;

    /**
     * projectId => ownedNFTAddress => ownedNFTProjectIds => bool
     * projects whose holders are allowed to purchase a token on `projectId`
     */
    mapping(uint256 => mapping(address => mapping(uint256 => bool)))
        public allowedProjectHolders;

    // function to restrict access to only AdminACL allowed calls
    // @dev defers which ACL contract is used to the core contract
    function _onlyCoreAdminACL(bytes4 _selector) internal {
        require(
            genArtCoreContract.adminACLAllowed(
                msg.sender,
                address(this),
                _selector
            ),
            "Only Core AdminACL allowed"
        );
    }

    function _onlyArtist(uint256 _projectId) internal view {
        require(
            msg.sender ==
                genArtCoreContract.projectIdToArtistAddress(_projectId),
            "Only Artist"
        );
    }

    /**
     * @notice Initializes contract to be a Filtered Minter for
     * `_minterFilter`, integrated with Art Blocks core contract
     * at address `_genArt721Address`.
     * @param _genArt721Address Art Blocks core contract for which this
     * contract will be a minter.
     * @param _minterFilter Minter filter for which
     * this will a filtered minter.
     * @param _delegationRegistryAddress Delegation registry contract address.
     */
    constructor(
        address _genArt721Address,
        address _minterFilter,
        address _delegationRegistryAddress
    ) ReentrancyGuard() MinterBase(_genArt721Address) {
        genArt721CoreAddress = _genArt721Address;
        genArtCoreContract = IGenArt721CoreContractV3WithRandomizer(
            _genArt721Address
        );
        delegationRegistryAddress = _delegationRegistryAddress;
        emit DelegationRegistryUpdated(_delegationRegistryAddress);
        delegationRegistryContract = IDelegationRegistry(
            _delegationRegistryAddress
        );
        minterFilterAddress = _minterFilter;
        minterFilter = IMinterFilterV0(_minterFilter);
        require(
            minterFilter.genArt721CoreAddress() == _genArt721Address,
            "Illegal contract pairing"
        );
        // currently, this minter only supports Engine V3 core contracts
        require(MinterBase.isEngine, "Only supports V3 Engine core");
    }

    /**
     * @notice Return whether or not a token has been used to mint a polyptych panel with the given ID
     * @param _panelId The ID of the polyptych panel being checked
     * @param _ownedNFTAddress ERC-721 NFT address holding the project token
     * owned by msg.sender being used to prove right to purchase
     * @param _ownedNFTTokenId ERC-721 NFT token ID owned by msg.sender being used
     * to prove right to purchase
     */
    function polyptychPanelMintedWithToken(
        uint24 _panelId,
        address _ownedNFTAddress,
        uint256 _ownedNFTTokenId
    ) external view returns (bool panelMinted) {
        bytes12 _tokenHash = IGenArt721CoreContractV3_Engine(_ownedNFTAddress)
            .tokenIdToHashSeed(_ownedNFTTokenId);
        require(_tokenHash != bytes32(0), "Invalid token hash seed");
        return polyptychPanelHashSeedIsMinted[_panelId][_tokenHash];
    }

    /**
     *
     * @notice Registers holders of NFTs at address `_NFTAddress` to be
     * considered for minting. New core address is assumed to follow syntax of:
     * `projectId = tokenId / 1_000_000`
     * @param _NFTAddress NFT core address to be registered.
     */
    function registerNFTAddress(address _NFTAddress) external {
        _onlyCoreAdminACL(this.registerNFTAddress.selector);
        // check that core contract implements the `tokenIdToHashSeed` function
        IGenArt721CoreContractV3WithRandomizer(_NFTAddress).tokenIdToHashSeed(
            0
        );
        _registeredNFTAddresses.add(_NFTAddress);
        emit RegisteredNFTAddress(_NFTAddress);
    }

    /**
     *
     * @notice Unregisters holders of NFTs at address `_NFTAddress` to be
     * considered for adding to future allowlists.
     * @param _NFTAddress NFT core address to be unregistered.
     */
    function unregisterNFTAddress(address _NFTAddress) external {
        _onlyCoreAdminACL(this.unregisterNFTAddress.selector);
        _registeredNFTAddresses.remove(_NFTAddress);
        emit UnregisteredNFTAddress(_NFTAddress);
    }

    /**
     * @notice Allows holders of NFTs at addresses `_ownedNFTAddressesAdd`,
     * project IDs `_ownedNFTProjectIdsAdd` to mint on project `_projectId`.
     * Also removes holders of NFTs at addresses `_ownedNFTAddressesRemove`,
     * project IDs `_ownedNFTProjectIdsRemove` from minting on project
     * `_projectId`.
     * `_ownedNFTAddressesAdd` assumed to be aligned with
     * `_ownedNFTProjectIdsAdd`.
     * e.g. Allows holders of project `_ownedNFTProjectIdsAdd[0]` on token
     * contract `_ownedNFTAddressesAdd[0]` to mint `_projectId`.
     * `_ownedNFTAddressesRemove` also assumed to be aligned with
     * `_ownedNFTProjectIdsRemove`.
     * @param _projectId Project ID to enable minting on.
     * @param _ownedNFTAddressesAdd NFT core addresses of projects to be
     * allowlisted. Indexes must align with `_ownedNFTProjectIdsAdd`.
     * @param _ownedNFTProjectIdsAdd Project IDs on `_ownedNFTAddressesAdd`
     * whose holders shall be allowlisted to mint project `_projectId`. Indexes
     * must align with `_ownedNFTAddressesAdd`.
     * @param _ownedNFTAddressesRemove NFT core addresses of projects to be
     * removed from allowlist. Indexes must align with
     * `_ownedNFTProjectIdsRemove`.
     * @param _ownedNFTProjectIdsRemove Project IDs on
     * `_ownedNFTAddressesRemove` whose holders will be removed from allowlist
     * to mint project `_projectId`. Indexes must align with
     * `_ownedNFTAddressesRemove`.
     * @dev if a project is included in both add and remove arrays, it will be
     * removed.
     */
    function allowRemoveHoldersOfProjects(
        uint256 _projectId,
        address[] memory _ownedNFTAddressesAdd,
        uint256[] memory _ownedNFTProjectIdsAdd,
        address[] memory _ownedNFTAddressesRemove,
        uint256[] memory _ownedNFTProjectIdsRemove
    ) external {
        _onlyArtist(_projectId);
        allowHoldersOfProjects(
            _projectId,
            _ownedNFTAddressesAdd,
            _ownedNFTProjectIdsAdd
        );
        removeHoldersOfProjects(
            _projectId,
            _ownedNFTAddressesRemove,
            _ownedNFTProjectIdsRemove
        );
    }

    /**
     * @notice Syncs local maximum invocations of project `_projectId` based on
     * the value currently defined in the core contract.
     * @param _projectId Project ID to set the maximum invocations for.
     * @dev this enables gas reduction after maxInvocations have been reached -
     * core contracts shall still enforce a maxInvocation check during mint.
     */
    function setProjectMaxInvocations(uint256 _projectId) public {
        uint256 maxInvocations;
        uint256 invocations;
        (invocations, maxInvocations, , , , ) = genArtCoreContract
            .projectStateData(_projectId);
        // update storage with results
        projectConfig[_projectId].maxInvocations = uint24(maxInvocations);

        // We need to ensure maxHasBeenInvoked is correctly set after manually syncing the
        // local maxInvocations value with the core contract's maxInvocations value.
        // This synced value of maxInvocations from the core contract will always be greater
        // than or equal to the previous value of maxInvocations stored locally.
        projectConfig[_projectId].maxHasBeenInvoked =
            invocations == maxInvocations;

        emit ProjectMaxInvocationsLimitUpdated(_projectId, maxInvocations);
    }

    /**
     * @notice Manually sets the local maximum invocations of project `_projectId`
     * with the provided `_maxInvocations`, checking that `_maxInvocations` is less
     * than or equal to the value of project `_project_id`'s maximum invocations that is
     * set on the core contract.
     * @dev Note that a `_maxInvocations` of 0 can only be set if the current `invocations`
     * value is also 0 and this would also set `maxHasBeenInvoked` to true, correctly short-circuiting
     * this minter's purchase function, avoiding extra gas costs from the core contract's maxInvocations check.
     * @param _projectId Project ID to set the maximum invocations for.
     * @param _maxInvocations Maximum invocations to set for the project.
     */
    function manuallyLimitProjectMaxInvocations(
        uint256 _projectId,
        uint256 _maxInvocations
    ) external {
        _onlyArtist(_projectId);
        // CHECKS
        // ensure that the manually set maxInvocations is not greater than what is set on the core contract
        uint256 maxInvocations;
        uint256 invocations;
        (invocations, maxInvocations, , , , ) = genArtCoreContract
            .projectStateData(_projectId);
        require(
            _maxInvocations <= maxInvocations,
            "Cannot increase project max invocations above core contract set project max invocations"
        );
        require(
            _maxInvocations >= invocations,
            "Cannot set project max invocations to less than current invocations"
        );

        // EFFECTS
        // update storage with results
        projectConfig[_projectId].maxInvocations = uint24(_maxInvocations);
        // We need to ensure maxHasBeenInvoked is correctly set after manually setting the
        // local maxInvocations value.
        projectConfig[_projectId].maxHasBeenInvoked =
            invocations == _maxInvocations;

        emit ProjectMaxInvocationsLimitUpdated(_projectId, _maxInvocations);
    }

    /**
     * @notice Updates this minter's price per token of project `_projectId`
     * to be '_pricePerTokenInWei`, in Wei.
     * This price supersedes any legacy core contract price per token value.
     * @dev Note that it is intentionally supported here that the configured
     * price may be explicitly set to `0`.
     */
    function updatePricePerTokenInWei(
        uint256 _projectId,
        uint256 _pricePerTokenInWei
    ) external {
        _onlyArtist(_projectId);
        ProjectConfig storage _projectConfig = projectConfig[_projectId];
        _projectConfig.pricePerTokenInWei = _pricePerTokenInWei;
        _projectConfig.priceIsConfigured = true;
        emit PricePerTokenInWeiUpdated(_projectId, _pricePerTokenInWei);

        // sync local max invocations if not initially populated
        // @dev if local max invocations and maxHasBeenInvoked are both
        // initial values, we know they have not been populated.
        if (
            _projectConfig.maxInvocations == 0 &&
            _projectConfig.maxHasBeenInvoked == false
        ) {
            setProjectMaxInvocations(_projectId);
        }
    }

    /**
     * @notice Updates payment currency of project `_projectId` to be
     * `_currencySymbol` at address `_currencyAddress`.
     * @param _projectId Project ID to update.
     * @param _currencySymbol Currency symbol.
     * @param _currencyAddress Currency address.
     */
    function updateProjectCurrencyInfo(
        uint256 _projectId,
        string memory _currencySymbol,
        address _currencyAddress
    ) external {
        _onlyArtist(_projectId);
        // require null address if symbol is "ETH"
        require(
            (keccak256(abi.encodePacked(_currencySymbol)) ==
                keccak256(abi.encodePacked("ETH"))) ==
                (_currencyAddress == address(0)),
            "ETH is only null address"
        );
        projectConfig[_projectId].currencySymbol = _currencySymbol;
        projectConfig[_projectId].currencyAddress = _currencyAddress;
        emit ProjectCurrencyInfoUpdated(
            _projectId,
            _currencyAddress,
            _currencySymbol
        );
    }

    /**
     * @notice Purchases a token from project `_projectId`.
     * @param _projectId Project ID to mint a token on.
     * @param _ownedNFTAddress ERC-721 NFT address holding the project token
     * owned by msg.sender being used to prove right to purchase.
     * @param _ownedNFTTokenId ERC-721 NFT token ID owned by msg.sender being used
     * to prove right to purchase.
     * @return tokenId Token ID of minted token
     */
    function purchase(
        uint256 _projectId,
        address _ownedNFTAddress,
        uint256 _ownedNFTTokenId
    ) external payable returns (uint256 tokenId) {
        tokenId = purchaseTo_dlc(
            msg.sender,
            _projectId,
            _ownedNFTAddress,
            _ownedNFTTokenId,
            address(0)
        );
        return tokenId;
    }

    /**
     * @notice gas-optimized version of purchase(uint256,address,uint256).
     */
    function purchase_nnf(
        uint256 _projectId,
        address _ownedNFTAddress,
        uint256 _ownedNFTTokenId
    ) external payable returns (uint256 tokenId) {
        tokenId = purchaseTo_dlc(
            msg.sender,
            _projectId,
            _ownedNFTAddress,
            _ownedNFTTokenId,
            address(0)
        );
        return tokenId;
    }

    /**
     * @notice Purchases a token from project `_projectId` and sets
     * the token's owner to `_to`.
     * @param _to Address to be the new token's owner.
     * @param _projectId Project ID to mint a token on.
     * @param _ownedNFTAddress ERC-721 NFT holding the project token owned by
     * msg.sender being used to claim right to purchase.
     * @param _ownedNFTTokenId ERC-721 NFT token ID owned by msg.sender being used
     * to claim right to purchase.
     * @return tokenId Token ID of minted token
     */
    function purchaseTo(
        address _to,
        uint256 _projectId,
        address _ownedNFTAddress,
        uint256 _ownedNFTTokenId
    ) external payable returns (uint256 tokenId) {
        return
            purchaseTo_dlc(
                _to,
                _projectId,
                _ownedNFTAddress,
                _ownedNFTTokenId,
                address(0)
            );
    }

    /**
     * @notice Purchases a token from project `_projectId` and sets
     *         the token's owner to `_to`, as a delegate, (the `msg.sender`)
     *         on behalf of an explicitly defined vault.
     * @param _to Address to be the new token's owner.
     * @param _projectId Project ID to mint a token on.
     * @param _ownedNFTAddress ERC-721 NFT address holding the project token owned by
     *         _vault (or msg.sender if no _vault is provided) being used to claim right to purchase.
     * @param _ownedNFTTokenId ERC-721 NFT token ID owned by _vault (or msg.sender if
     *         no _vault is provided) being used to claim right to purchase.
     * @param _vault Vault being purchased on behalf of.  Acceptable to be `address(0)` if no vault.
     * @return tokenId Token ID of minted token
     */
    function purchaseTo(
        address _to,
        uint256 _projectId,
        address _ownedNFTAddress,
        uint256 _ownedNFTTokenId,
        address _vault
    ) external payable returns (uint256 tokenId) {
        return
            purchaseTo_dlc(
                _to,
                _projectId,
                _ownedNFTAddress,
                _ownedNFTTokenId,
                _vault
            );
    }

    /**
     * @notice Inactive function - requires NFT ownership to purchase.
     */
    function purchase(uint256) external payable returns (uint256) {
        revert("Must claim NFT ownership");
    }

    /**
     * @notice Warning: Disabling purchaseTo is not supported on this minter.
     * This method exists purely for interface-conformance purposes.
     */
    function togglePurchaseToDisabled(uint256 _projectId) external view {
        _onlyArtist(_projectId);
        revert("Action not supported");
    }

    /**
     * @notice projectId => has project reached its maximum number of
     * invocations? Note that this returns a local cache of the core contract's
     * state, and may be out of sync with the core contract. This is
     * intentional, as it only enables gas optimization of mints after a
     * project's maximum invocations has been reached. A false negative will
     * only result in a gas cost increase, since the core contract will still
     * enforce a maxInvocation check during minting. A false positive is not
     * possible because the V3 core contract only allows maximum invocations
     * to be reduced, not increased. Based on this rationale, we intentionally
     * do not do input validation in this method as to whether or not the input
     * `_projectId` is an existing project ID.
     */
    function projectMaxHasBeenInvoked(
        uint256 _projectId
    ) external view returns (bool) {
        return projectConfig[_projectId].maxHasBeenInvoked;
    }

    /**
     * @notice projectId => project's maximum number of invocations.
     * Optionally synced with core contract value, for gas optimization.
     * Note that this returns a local cache of the core contract's
     * state, and may be out of sync with the core contract. This is
     * intentional, as it only enables gas optimization of mints after a
     * project's maximum invocations has been reached.
     * @dev A number greater than the core contract's project max invocations
     * will only result in a gas cost increase, since the core contract will
     * still enforce a maxInvocation check during minting. A number less than
     * the core contract's project max invocations is only possible when the
     * project's max invocations have not been synced on this minter, since the
     * V3 core contract only allows maximum invocations to be reduced, not
     * increased. When this happens, the minter will enable minting, allowing
     * the core contract to enforce the max invocations check. Based on this
     * rationale, we intentionally do not do input validation in this method as
     * to whether or not the input `_projectId` is an existing project ID.
     */
    function projectMaxInvocations(
        uint256 _projectId
    ) external view returns (uint256) {
        return uint256(projectConfig[_projectId].maxInvocations);
    }

    /**
     * @notice Gets your balance of the ERC-20 token currently set
     * as the payment currency for project `_projectId`.
     * @param _projectId Project ID to be queried.
     * @return balance Balance of ERC-20
     */
    function getYourBalanceOfProjectERC20(
        uint256 _projectId
    ) external view returns (uint256 balance) {
        balance = IERC20(projectConfig[_projectId].currencyAddress).balanceOf(
            msg.sender
        );
        return balance;
    }

    /**
     * @notice Gets your allowance for this minter of the ERC-20
     * token currently set as the payment currency for project
     * `_projectId`.
     * @param _projectId Project ID to be queried.
     * @return remaining Remaining allowance of ERC-20
     */
    function checkYourAllowanceOfProjectERC20(
        uint256 _projectId
    ) external view returns (uint256 remaining) {
        remaining = IERC20(projectConfig[_projectId].currencyAddress).allowance(
            msg.sender,
            address(this)
        );
        return remaining;
    }

    /**
     * @notice Gets quantity of NFT addresses registered on this minter.
     * @return uint256 quantity of NFT addresses registered
     */
    function getNumRegisteredNFTAddresses() external view returns (uint256) {
        return _registeredNFTAddresses.length();
    }

    /**
     * @notice Get registered NFT core contract address at index `_index` of
     * enumerable set.
     * @param _index enumerable set index to query.
     * @return NFTAddress NFT core contract address at index `_index`
     * @dev index must be < quantity of registered NFT addresses
     */
    function getRegisteredNFTAddressAt(
        uint256 _index
    ) external view returns (address NFTAddress) {
        return _registeredNFTAddresses.at(_index);
    }

    /**
     * @notice Gets if price of token is configured, price of minting a
     * token on project `_projectId`, and currency symbol and address to be
     * used as payment. Supersedes any core contract price information.
     * @param _projectId Project ID to get price information for.
     * @return isConfigured true only if token price has been configured on
     * this minter
     * @return tokenPriceInWei current price of token on this minter - invalid
     * if price has not yet been configured
     * @return currencySymbol currency symbol for purchases of project on this
     * minter. This minter always returns "ETH"
     * @return currencyAddress currency address for purchases of project on
     * this minter. This minter always returns null address, reserved for ether
     */
    function getPriceInfo(
        uint256 _projectId
    )
        external
        view
        returns (
            bool isConfigured,
            uint256 tokenPriceInWei,
            string memory currencySymbol,
            address currencyAddress
        )
    {
        ProjectConfig storage _projectConfig = projectConfig[_projectId];
        isConfigured = _projectConfig.priceIsConfigured;
        tokenPriceInWei = _projectConfig.pricePerTokenInWei;
        currencyAddress = _projectConfig.currencyAddress;
        if (currencyAddress == address(0)) {
            // defaults to ETH
            currencySymbol = "ETH";
        } else {
            currencySymbol = _projectConfig.currencySymbol;
        }
    }

    /**
     * @notice Inactive function - requires NFT ownership to purchase.
     */
    function purchaseTo(address, uint256) public payable returns (uint256) {
        revert("Must claim NFT ownership");
    }

    /**
     * @notice gas-optimized version of purchaseTo(address,uint256,address,uint256,address).
     * @param _to Address to be the new token's owner.
     * @param _projectId Project ID to mint a token on.
     * @param _ownedNFTAddress ERC-721 NFT address holding the project token owned by _vault
     *         (or msg.sender if no _vault is provided) being used to claim right to purchase.
     * @param _ownedNFTTokenId ERC-721 NFT token ID owned by _vault (or msg.sender if
     *         no _vault is provided) being used to claim right to purchase.
     * @param _vault Vault being purchased on behalf of. Acceptable to be `address(0)` if no vault.
     * @return tokenId Token ID of minted token
     */
    function purchaseTo_dlc(
        address _to,
        uint256 _projectId,
        address _ownedNFTAddress,
        uint256 _ownedNFTTokenId,
        address _vault
    ) public payable nonReentrant returns (uint256 tokenId) {
        // CHECKS
        ProjectConfig storage _projectConfig = projectConfig[_projectId];

        // Note that `maxHasBeenInvoked` is only checked here to reduce gas
        // consumption after a project has been fully minted.
        // `_projectConfig.maxHasBeenInvoked` is locally cached to reduce
        // gas consumption, but if not in sync with the core contract's value,
        // the core contract also enforces its own max invocation check during
        // minting.
        require(
            !_projectConfig.maxHasBeenInvoked,
            "Maximum number of invocations reached"
        );

        // require artist to have configured price of token on this minter
        require(_projectConfig.priceIsConfigured, "Price not configured");

        // require token used to claim to be in set of allowlisted NFTs
        require(
            isAllowlistedNFT(_projectId, _ownedNFTAddress, _ownedNFTTokenId),
            "Only allowlisted NFTs"
        );

        // NOTE: delegate-vault handling **begins here**.

        // handle that the vault may be either the `msg.sender` in the case
        // that there is not a true vault, or may be `_vault` if one is
        // provided explicitly (and it is valid).
        address vault = msg.sender;
        if (_vault != address(0)) {
            // If a vault is provided, it must be valid, otherwise throw rather
            // than optimistically-minting with original `msg.sender`.
            // Note, we do not check `checkDelegateForAll` or `checkDelegateForContract` as well,
            // as they are known to be implicitly checked by calling `checkDelegateForToken`.
            bool isValidVault = delegationRegistryContract
                .checkDelegateForToken(
                    msg.sender, // delegate
                    _vault, // vault
                    _ownedNFTAddress, // contract
                    _ownedNFTTokenId // tokenId
                );
            require(isValidVault, "Invalid delegate-vault pairing");
            vault = _vault;
        }

        // we need the new token ID in advance of the randomizer setting a token hash
        (uint256 _invocations, , , , , ) = genArtCoreContract.projectStateData(
            _projectId
        );

        address _artist = genArtCoreContract.projectIdToArtistAddress(
            _projectId
        );

        uint256 _newTokenId = (_projectId * ONE_MILLION) + _invocations;

        // EFFECTS

        // we need to store the new token ID before it is minted so the randomizer can query it
        IGenArt721CoreContractV3WithRandomizer _ownedNFTCoreContract = IGenArt721CoreContractV3WithRandomizer(
                _ownedNFTAddress
            );
        bytes12 _targetHashSeed = _ownedNFTCoreContract.tokenIdToHashSeed(
            _ownedNFTTokenId
        );

        _requireCurrentPanelIsMintedOnce(_projectId, _targetHashSeed);

        genArtCoreContract.randomizerContract().setPolyptychHashSeed(
            _newTokenId,
            _targetHashSeed
        );

        // once mint() is called, the polyptych randomizer will either:
        // 1) assign a random token hash
        // 2) if configured, obtain the token hash from the `polyptychSeedHashes` mapping
        tokenId = minterFilter.mint(_to, _projectId, vault);

        // NOTE: delegate-vault handling **ends here**.

        // redundant check against reentrancy
        bytes12 _assignedHashSeed = genArtCoreContract.tokenIdToHashSeed(
            tokenId
        );
        require(
            _assignedHashSeed == _targetHashSeed,
            "Unexpected token hash seed"
        );

        // invocation is token number plus one, and will never overflow due to
        // limit of 1e6 invocations per project. block scope for gas efficiency
        // (i.e. avoid an unnecessary var initialization to 0).
        unchecked {
            uint256 tokenInvocation = (tokenId % ONE_MILLION) + 1;
            uint256 localMaxInvocations = _projectConfig.maxInvocations;
            // handle the case where the token invocation == minter local max
            // invocations occurred on a different minter, and we have a stale
            // local maxHasBeenInvoked value returning a false negative.
            // @dev this is a CHECK after EFFECTS, so security was considered
            // in detail here.
            require(
                tokenInvocation <= localMaxInvocations,
                "Maximum invocations reached"
            );
            // in typical case, update the local maxHasBeenInvoked value
            // to true if the token invocation == minter local max invocations
            // (enables gas efficient reverts after sellout)
            if (tokenInvocation == localMaxInvocations) {
                _projectConfig.maxHasBeenInvoked = true;
            }
        }

        // INTERACTIONS
        // require sender to own NFT used to redeem
        /**
         * @dev Considered an interaction because calling ownerOf on an NFT
         * contract. Plan is to only register AB/PBAB NFTs on the minter, but
         * in case other NFTs are registered, better to check here. Also,
         * function is non-reentrant, so being extra cautious.
         */
        if (msg.sender == _artist) {
            require(
                IERC721(_ownedNFTAddress).ownerOf(_ownedNFTTokenId) == _to,
                "Only owner of NFT"
            );
        } else {
            require(
                IERC721(_ownedNFTAddress).ownerOf(_ownedNFTTokenId) == vault,
                "Only owner of NFT"
            );
        }

        // split funds
        uint256 pricePerTokenInWei = _projectConfig.pricePerTokenInWei;
        address currencyAddress = _projectConfig.currencyAddress;
        if (currencyAddress != address(0)) {
            require(
                msg.value == 0,
                "this project accepts a different currency and cannot accept ETH"
            );
            require(
                IERC20(currencyAddress).allowance(msg.sender, address(this)) >=
                    pricePerTokenInWei,
                "Insufficient Funds Approved for TX"
            );
            require(
                IERC20(currencyAddress).balanceOf(msg.sender) >=
                    pricePerTokenInWei,
                "Insufficient balance."
            );
            splitFundsERC20(
                _projectId,
                pricePerTokenInWei,
                currencyAddress,
                genArt721CoreAddress
            );
        } else {
            require(
                msg.value >= pricePerTokenInWei,
                "Must send minimum value to mint!"
            );
            splitFundsETH(_projectId, pricePerTokenInWei, genArt721CoreAddress);
        }

        return tokenId;
    }

    /**
     * @notice Allows holders of NFTs at addresses `_ownedNFTAddresses`,
     * project IDs `_ownedNFTProjectIds` to mint on project `_projectId`.
     * `_ownedNFTAddresses` assumed to be aligned with `_ownedNFTProjectIds`.
     * e.g. Allows holders of project `_ownedNFTProjectIds[0]` on token
     * contract `_ownedNFTAddresses[0]` to mint `_projectId`.
     * @param _projectId Project ID to enable minting on.
     * @param _ownedNFTAddresses NFT core addresses of projects to be
     * allowlisted. Indexes must align with `_ownedNFTProjectIds`.
     * @param _ownedNFTProjectIds Project IDs on `_ownedNFTAddresses` whose
     * holders shall be allowlisted to mint project `_projectId`. Indexes must
     * align with `_ownedNFTAddresses`.
     */
    function allowHoldersOfProjects(
        uint256 _projectId,
        address[] memory _ownedNFTAddresses,
        uint256[] memory _ownedNFTProjectIds
    ) public {
        _onlyArtist(_projectId);
        // require same length arrays
        require(
            _ownedNFTAddresses.length == _ownedNFTProjectIds.length,
            "Length of add arrays must match"
        );
        // for each approved project
        for (uint256 i = 0; i < _ownedNFTAddresses.length; i++) {
            // ensure registered address
            require(
                _registeredNFTAddresses.contains(_ownedNFTAddresses[i]),
                "Only Registered NFT Addresses"
            );
            // approve
            allowedProjectHolders[_projectId][_ownedNFTAddresses[i]][
                _ownedNFTProjectIds[i]
            ] = true;
        }
        // emit approve event
        emit AllowedHoldersOfProjects(
            _projectId,
            _ownedNFTAddresses,
            _ownedNFTProjectIds
        );
    }

    /**
     * @notice Removes holders of NFTs at addresses `_ownedNFTAddresses`,
     * project IDs `_ownedNFTProjectIds` to mint on project `_projectId`. If
     * other projects owned by a holder are still allowed to mint, holder will
     * maintain ability to purchase.
     * `_ownedNFTAddresses` assumed to be aligned with `_ownedNFTProjectIds`.
     * e.g. Removes holders of project `_ownedNFTProjectIds[0]` on token
     * contract `_ownedNFTAddresses[0]` from mint allowlist of `_projectId`.
     * @param _projectId Project ID to enable minting on.
     * @param _ownedNFTAddresses NFT core addresses of projects to be removed
     * from allowlist. Indexes must align with `_ownedNFTProjectIds`.
     * @param _ownedNFTProjectIds Project IDs on `_ownedNFTAddresses` whose
     * holders will be removed from allowlist to mint project `_projectId`.
     * Indexes must align with `_ownedNFTAddresses`.
     */
    function removeHoldersOfProjects(
        uint256 _projectId,
        address[] memory _ownedNFTAddresses,
        uint256[] memory _ownedNFTProjectIds
    ) public {
        _onlyArtist(_projectId);
        // require same length arrays
        require(
            _ownedNFTAddresses.length == _ownedNFTProjectIds.length,
            "Length of remove arrays must match"
        );
        // for each removed project
        for (uint256 i = 0; i < _ownedNFTAddresses.length; i++) {
            // revoke
            allowedProjectHolders[_projectId][_ownedNFTAddresses[i]][
                _ownedNFTProjectIds[i]
            ] = false;
        }
        // emit removed event
        emit RemovedHoldersOfProjects(
            _projectId,
            _ownedNFTAddresses,
            _ownedNFTProjectIds
        );
    }

    /**
     * @notice Allows the artist to increment the minter to the next polyptych panel
     * @param _projectId Project ID to increment to its next polyptych panel
     */
    function incrementPolyptychProjectPanelId(uint256 _projectId) public {
        _onlyArtist(_projectId);
        projectConfig[_projectId].polyptychPanelId++;
    }

    /**
     * @notice Returns if token is an allowlisted NFT for project `_projectId`.
     * @param _projectId Project ID to be checked.
     * @param _ownedNFTAddress ERC-721 NFT token address to be checked.
     * @param _ownedNFTTokenId ERC-721 NFT token ID to be checked.
     * @return bool Token is allowlisted
     * @dev does not check if token has been used to purchase
     * @dev assumes project ID can be derived from tokenId / 1_000_000
     */
    function isAllowlistedNFT(
        uint256 _projectId,
        address _ownedNFTAddress,
        uint256 _ownedNFTTokenId
    ) public view returns (bool) {
        uint256 ownedNFTProjectId = _ownedNFTTokenId / ONE_MILLION;
        return
            allowedProjectHolders[_projectId][_ownedNFTAddress][
                ownedNFTProjectId
            ];
    }

    function _requireCurrentPanelIsMintedOnce(
        uint256 _projectId,
        bytes12 _tokenHashSeed
    ) private {
        // mark the polyptych panel as minted so the same panel cannot be minted twice
        uint256 _panelId = projectConfig[_projectId].polyptychPanelId;

        require(
            _tokenHashSeed != bytes12(0),
            "Cannot have an empty hash seed to copy."
        );

        require(
            !polyptychPanelHashSeedIsMinted[_panelId][_tokenHashSeed],
            "Panel already minted"
        );
        polyptychPanelHashSeedIsMinted[_panelId][_tokenHashSeed] = true;
    }
}
