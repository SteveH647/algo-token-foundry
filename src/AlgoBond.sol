// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "abdk/ABDKMathQuad.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./AlgoToken.sol";


/**
 * @title AlgoBond
 * @dev NFT bonds that lock AlgoTokens in exchange for yield
 * 
 * Three bond types:
 * - DECAY: Principal and gains unlock gradually over time
 * - GAINSONLY: Principal stays locked, only gains are paid out
 * - REINVEST: All gains are automatically reinvested
 * 
 * Bonds are represented as NFTs for easy transfer and management
 */
contract AlgoBond is ERC721 {
    using Address for address;
    using Strings for uint256;
    
    // High-precision math library
    using ABDKMathQuad for uint256;
    using ABDKMathQuad for int256;
    using ABDKMathQuad for bytes16;
    
    // Mathematical constants
    bytes16 f_1 = uint256(1).fromUInt(); // 1.0
    bytes16 f_e = f_1.exp(); // e ≈ 2.718

    // ============================================
    // EXTERNAL CONTRACTS
    // ============================================

    // The ERC20 contract of the tokes that can be locked in bonds
    AlgoToken algoToken;

    // ============================================
    // TOKEN OWNERSHIP TRACKING
    // ============================================
    
    // Token name
    string private _name;
    
    // Token symbol
    string private _symbol;
    
    // Mapping from token ID to owner address
    mapping(uint256 => address) private _owners;
    
    // Mapping of owner address to list of token IDs owned
    mapping(address => uint256[]) private _tokensOwned;
    
    // Mapping owner address to token count
    mapping(address => uint256) private _balances;
    
    // Mapping from token ID to approved address
    mapping(uint256 => address) private _tokenApprovals;
    
    // Mapping from owner to operator approvals
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // ============================================
    // BOND VALUE TRACKING
    // ============================================
    
    /**
     * @dev Current balance of each bond
     * Decreases over time for DECAY bonds
     * Stays constant for GAINSONLY
     * Increases for REINVEST
     */
    mapping(uint256 => uint256) public _bondBalance;
    
    /**
     * @dev Largest balance the bond has ever had
     * Used to determine maturity acceleration threshold
     */
    mapping(uint256 => uint256) private _largestBondBalance;
    
    /**
     * @dev Counter for minting new NFT IDs
     */
    uint256 public _currentTokenId = 0;

    // ============================================
    // BOND SUM ARRAYS
    // ============================================
    
    /**
     * @dev Running sum of all bond values after each update
     * Each index represents a time slice between updates
     */
    uint256[] public _bSum;
    
    /**
     * @dev Pending bond value to be added at next update
     */
    uint256 public _bDelayedSum = 0;
    
    /**
     * @dev Sum of DECAY bonds (principal+gains that unlock over time)
     * Values decay exponentially based on maturity period
     */
    uint256[] public _bDecaySum;
    uint256 public _bDelayedDecaySum = 0;
    
    /**
     * @dev Sum of GAINSONLY bonds (principal locked, gains paid)
     * Principal amount stays constant
     */
    uint256[] public _bGainsOnlySum;
    uint256 public _bDelayedGainsOnlySum = 0;
    
    /**
     * @dev Sum of REINVEST bonds (all gains reinvested)
     * Grows over time as gains compound
     */
    uint256[] public _bReinvestSum;
    uint256 public _bDelayedReinvestSum = 0;
    
    /**
     * @dev Accumulated gains waiting to be distributed
     * Applied to bonds on next updateBondSums() call
     */
    uint256 public bGainsAccrual = 0;
    
    /**
     * @dev Total payouts for DECAY bonds at each update
     */
    uint256[] public _bPayoutDecaySum;
    
    /**
     * @dev Total payouts for GAINSONLY bonds at each update
     */
    uint256[] public _bPayoutGainsOnlySum;
    
    /**
     * @dev Block number of each update for time calculations
     */
    uint256[] public _blockNumbers;
    
    /**
     * @dev Last update index for each bond
     * Tracks which gains have already been claimed
     */
    mapping(uint256 => uint256) private _updateCountOfIndividualBond;
    
    /**
     * @dev Bond type for each token ID
     */
    enum BondReturnsOption{DECAY, GAINSONLY, REINVEST}
    mapping(uint256 => BondReturnsOption) private _bondReturnsOption;
    
    /**
     * @dev Only the AlgoToken contract can mint/burn bonds
     */
    address public bondManager;
    
    /**
     * @dev Threshold for bond maturity acceleration
     * When bond_balance/original_balance <= this ratio,
     * the entire remaining balance is immediately redeemable
     */
    bytes16 public _bondPortionAtMaturity;
    
    /**
     * @dev Time period over which bonds decay (in blocks)
     * Set to 1.618 * bear_market_length (golden ratio)
     */
    bytes16 public maturityTimeSpan;
    
    /**
     * @dev Current index in the sum arrays
     */
    uint256 public _sumsIndex = 0;
    
    // Temporary variables for calculations
    // (Declared at contract level due to stack depth issues)
    uint256 private i_blocksSinceLastBondSumUpdate;
    bytes16 private f_bondGains;
    bytes16 private bondGainsDecay;
    bytes16 private bondGainsOnly;
    bytes16 private bondGainsReinvest;
    uint256 private decaySumToPush;

    // ============================================
    // CONSTRUCTOR
    // ============================================
    
    /**
     * @param name_ NFT collection name
     * @param symbol_ NFT collection symbol
     * @param bondPortionAtMaturity_ Ratio for maturity acceleration
     */
    constructor(
        string memory name_,
        string memory symbol_,
        // address bondManager_,
        bytes16 bondPortionAtMaturity_
    ) ERC721 (name_, symbol_) {
        // bondManager = bondManager_;
        
        // Initialize arrays with zero values
        _bSum.push(0);
        _bDecaySum.push(0);
        _bPayoutDecaySum.push(0);
        _bGainsOnlySum.push(0);
        _bPayoutGainsOnlySum.push(0);
        _bReinvestSum.push(0);
        
        _blockNumbers.push(block.number);
        
        _bondPortionAtMaturity = bondPortionAtMaturity_;
    }

    // ============================================
    // BOND MINTING FUNCTIONS
    // ============================================
    
    /**
     * @dev Mint a new bond NFT
     * @param to Recipient address
     * @param bondBalance_ Amount of AlgoTokens to lock
     * @param bondType Type of bond returns
     * @return Token ID of the new bond
     */
    function mint(
        address to, 
        uint256 bondBalance_, 
        BondReturnsOption bondType
    ) public returns(uint256) {
        require(msg.sender == bondManager, "Sender address must be bond manager");
        return mint(to, bondBalance_, bondBalance_, bondType);
    }
    
    /**
     * @dev Internal mint function with separate original balance tracking
     * @param to Recipient address
     * @param bondBalance_ Current bond balance
     * @param originalBondBalance_ Original balance for maturity calculations
     * @param bondType Type of bond returns
     * @return Token ID of the new bond
     */
    function mint(
        address to, 
        uint256 bondBalance_, 
        uint256 originalBondBalance_, 
        BondReturnsOption bondType
    ) public returns(uint256) {
        require(msg.sender == bondManager, "Sender address must be bond manager");
        
        // Mint the NFT
        _safeMint(to, _currentTokenId);
        
        // Set bond properties
        _bondBalance[_currentTokenId] = bondBalance_;
        _largestBondBalance[_currentTokenId] = originalBondBalance_;
        _tokensOwned[to].push(_currentTokenId);
        
        // Set update count to next index (gains start from next period)
        _updateCountOfIndividualBond[_currentTokenId] = _sumsIndex + 1;
        
        // Add to delayed sums (applied at next update)
        _bDelayedSum += bondBalance_;
        
        if (bondType == BondReturnsOption.DECAY) {
            _bDelayedDecaySum += bondBalance_;
        }
        else if (bondType == BondReturnsOption.GAINSONLY) {
            _bDelayedGainsOnlySum += bondBalance_;
        }
        else { // BondReturnsOption.REINVEST
            _bDelayedReinvestSum += bondBalance_;
        }
        
        _bondReturnsOption[_currentTokenId] = bondType;
        
        _currentTokenId++;
        
        return _currentTokenId - 1;
    }

    /**
     * @dev Burn a bond NFT and remove its value from sums
     * @param tokenId Bond to burn
     */
    function burn(uint256 tokenId) public {
        require(msg.sender == bondManager, "Sender address must be bond manager");
        _burn(tokenId);
        delete _bondBalance[tokenId];
        delete _largestBondBalance[tokenId];
        deleteTokenOwned(tokenId);
    }
    
    /**
     * @dev Remove token from owner's list
     * @param tokenId Token to remove
     */
    function deleteTokenOwned(uint256 tokenId) private {
        bool tokenFound = false;
        for (uint i = 0; i < _tokensOwned[_owners[tokenId]].length && !tokenFound; i++) {
            if (_tokensOwned[_owners[tokenId]][i] == tokenId) {
                delete _tokensOwned[_owners[tokenId]][i];
                tokenFound = true;
            }
        }
    }

    /**
     * @dev Add more AlgoTokens to an existing bond
     * @param tokenId Bond to add to
     * @param bondAmount Amount to add
     * @return Payout from updating the bond before adding
     */
    function addToBond(uint256 tokenId, uint256 bondAmount) public returns(uint256) {
        require(msg.sender == bondManager, "Sender address must be bond manager");
        
        // Update bond first to claim any pending gains
        uint256 payout = updateBond(tokenId);
        
        uint256 bondBalanceBeforeAddition = _bondBalance[tokenId];
        uint256 bondSum = bondAmount + bondBalanceBeforeAddition;
        
        // Update largest balance if this exceeds it
        if (bondSum > _largestBondBalance[tokenId] || _bondBalance[tokenId] == 0) {
            _largestBondBalance[tokenId] = bondSum;
        }
        
        _bondBalance[tokenId] = bondSum;
        
        // Add to delayed sums
        _bDelayedSum += bondAmount;
        BondReturnsOption bondType = _bondReturnsOption[tokenId];
        if (bondType == BondReturnsOption.DECAY) {
            _bDelayedDecaySum += bondAmount;
        }
        else if (bondType == BondReturnsOption.GAINSONLY) {
            _bDelayedGainsOnlySum += bondAmount;
        }
        else { // BondReturnsOption.REINVEST
            _bDelayedReinvestSum += bondAmount;
        }
        
        return payout;
    }

    /**
     * @dev Set the maturity timespan for bond decay calculations
     * @param mts New maturity timespan in blocks
     */
    function setMaturityTimeSpan(bytes16 mts) public {
        require(msg.sender == bondManager, "Sender address must be bond manager");
        maturityTimeSpan = mts;
    }

    /**
     * @dev Update all bond sums with accumulated gains
     * Distributes gains proportionally to all bonds
     * Can only be called periodically (e.g., monthly)
     */
    function updateBondSums() public {
        _sumsIndex = _bSum.length - 1;
        
        if (_bSum[_sumsIndex] > 0 && bGainsAccrual > 0) {
            // Calculate gains distribution for each bond type
            
            bytes16 bSum_ = _bSum[_sumsIndex].fromUInt();
            bytes16 bDecaySum_ = _bDecaySum[_sumsIndex].fromUInt();
            bytes16 bGainsOnlySum_ = _bGainsOnlySum[_sumsIndex].fromUInt();
            bytes16 bReinvestSum_ = _bReinvestSum[_sumsIndex].fromUInt();
            
            // Distribute gains proportionally to each bond type
            f_bondGains = bGainsAccrual.fromUInt();
            bondGainsDecay = f_bondGains.mul(bDecaySum_.div(bSum_));
            bondGainsOnly = f_bondGains.mul(bGainsOnlySum_.div(bSum_));
            bondGainsReinvest = f_bondGains.mul(bReinvestSum_.div(bSum_));
            bGainsAccrual = 0;
            
            // Calculate time since last update
            i_blocksSinceLastBondSumUpdate = block.number - _blockNumbers[_sumsIndex];
            bytes16 blocksSinceLastUpdate = i_blocksSinceLastBondSumUpdate.fromUInt();
            
            uint256 _sumsIndexminus_1 = _sumsIndex;
            _sumsIndex++;
            
            // ========== DECAY BONDS ==========
            // Apply exponential decay: balance * e^(-time/maturity)
            
            bytes16 prePayoutDecaySum = bDecaySum_.add(bondGainsDecay);
            
            // Calculate decay factor
            bytes16 Dt_T = blocksSinceLastUpdate.div(maturityTimeSpan);
            bytes16 e_dt_T = Dt_T.neg().exp();
            
            // New sum after decay
            decaySumToPush = prePayoutDecaySum.mul(e_dt_T).toUInt();
            _bDecaySum.push(decaySumToPush);
            
            // Payout is the decayed amount
            uint256 i_bPayoutDecaySum = prePayoutDecaySum.toUInt() - _bDecaySum[_sumsIndex];
            _bPayoutDecaySum.push(i_bPayoutDecaySum);
            
            // ========== GAINSONLY BONDS ==========
            // Principal stays locked, only gains paid out
            
            uint256 i_bGainsOnlySum = _bGainsOnlySum[_sumsIndexminus_1];
            _bGainsOnlySum.push(i_bGainsOnlySum);
            _bPayoutGainsOnlySum.push(bondGainsOnly.toUInt());
            
            // ========== REINVEST BONDS ==========
            // All gains reinvested, no payout
            
            uint256 i_bReinvestSum = bReinvestSum_.toUInt() + bondGainsReinvest.toUInt();
            _bReinvestSum.push(i_bReinvestSum);
            
            // Update total sum
            _bSum.push(_bDecaySum[_sumsIndex] + i_bGainsOnlySum + i_bReinvestSum);
        } else {
            // No gains to distribute, just copy previous values
            _bSum.push(_bSum[_sumsIndex]);
            _bDecaySum.push(_bDecaySum[_sumsIndex]);
            _bGainsOnlySum.push(_bGainsOnlySum[_sumsIndex]);
            _bReinvestSum.push(_bReinvestSum[_sumsIndex]);
            _sumsIndex++;
        }
        
        _blockNumbers.push(block.number);
        
        // Add delayed sums to active sums
        _bSum[_sumsIndex] += _bDelayedSum;
        _bDecaySum[_sumsIndex] += _bDelayedDecaySum;
        _bGainsOnlySum[_sumsIndex] += _bDelayedGainsOnlySum;
        _bReinvestSum[_sumsIndex] += _bDelayedReinvestSum;
        
        // Reset delayed sums
        _bDelayedSum = 0;
        _bDelayedDecaySum = 0;
        _bDelayedGainsOnlySum = 0;
        _bDelayedReinvestSum = 0;
    }

    /**
     * @dev Update an individual bond to claim gains
     * @param tokenId Bond to update
     * @return Total payout amount
     */
    function updateBond(uint256 tokenId) public returns (uint256) {
        require(msg.sender == bondManager, "Sender address must be bond manager");
        
        uint256 updateCount = _updateCountOfIndividualBond[tokenId];
        uint256 payout = 0;
        uint256 bondBalance_ = _bondBalance[tokenId];
        uint256 newBondBalance = bondBalance_;
        
        // Only process if bond has existed for at least one update period
        if (updateCount < _sumsIndex) {
            BondReturnsOption bondReturnsOption_ = _bondReturnsOption[tokenId];
            
            if (bondReturnsOption_ == BondReturnsOption.DECAY) {
                // ========== DECAY BOND ==========
                // Calculate payouts for each time slice
                for (uint i = updateCount + 1; i <= _sumsIndex; i++) {
                    payout += _bPayoutDecaySum[i] * bondBalance_ / _bDecaySum[i-1];
                }
                
                // Update bond balance (decays proportionally with sum)
                newBondBalance = bondBalance_ * _bDecaySum[_sumsIndex] / _bDecaySum[updateCount];
                
                // Check if bond has matured (decayed below threshold)
                if (bondIsRedeemable(tokenId)) {
                    // Redeem entire remaining balance
                    payout += newBondBalance;
                    
                    // Remove from sums
                    _bDecaySum[_sumsIndex] -= newBondBalance;
                    _bSum[_sumsIndex] -= newBondBalance;
                    
                    newBondBalance = 0;
                    _bondBalance[tokenId] = 0;
                    burn(tokenId);
                }
            }
            else if (bondReturnsOption_ == BondReturnsOption.GAINSONLY) {
                // ========== GAINSONLY BOND ==========
                // Calculate gain payouts for each time slice
                for (uint i = updateCount + 1; i <= _sumsIndex; i++) {
                    payout += _bPayoutGainsOnlySum[i] * bondBalance_ / _bGainsOnlySum[i-1];
                }
                // Principal remains unchanged
            }
            else { // BondReturnsOption.REINVEST
                // ========== REINVEST BOND ==========
                // No payout, balance grows
                newBondBalance = bondBalance_ * _bReinvestSum[_sumsIndex] / _bReinvestSum[updateCount];
            }
            
            // Update bond state
            _bondBalance[tokenId] = newBondBalance;
            _updateCountOfIndividualBond[tokenId] = _sumsIndex;
        }
        
        return payout;
    }

    /**
     * @dev Change bond type (requires updating first)
     * @param tokenId Bond to change
     * @param toBondType New bond type
     * @return Payout from required update
     */
    function ChangeBondType(uint256 tokenId, BondReturnsOption toBondType) public returns (uint256) {
        require(msg.sender == bondManager, "Sender address must be bond manager");
        require(_exists(tokenId));
        
        // Must update bond before changing type
        uint256 payout = updateBond(tokenId);
        
        // Change the type
        _bondReturnsOption[tokenId] = toBondType;
        
        return payout;
    }

    /**
     * @dev Check if bond has decayed enough for full redemption
     * @param tokenId Bond to check
     * @return True if redeemable
     */
    function bondIsRedeemable(uint256 tokenId) internal view returns (bool) {
        // Redeem when current/original ratio <= threshold
        return _bondBalance[tokenId].fromUInt().div(
            _largestBondBalance[tokenId].fromUInt()
        ).cmp(_bondPortionAtMaturity) <= 0;
    }

    /**
     * @dev Add gains that will be distributed at next update
     * @param bondGains Amount of gains to add
     */
    function addToGainsAccrual(uint256 bondGains) public {
        bGainsAccrual += bondGains;
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================
    
    function get_bSumLength() public view returns (uint256) {
        return _bSum.length;
    }
    
    function get_blockNumbersAt(uint256 index) public view returns (uint256) {
        return _blockNumbers[index];
    }
    
    /**
     * @dev Get total AlgoTokens locked in all bonds
     * @return Total locked amount including pending gains
     */
    function getTotalAlgosLockedInBonds() public view returns (uint256) {
        return _bSum[_bSum.length - 1] + _bDelayedSum + bGainsAccrual;
    }

    /**
     * @dev Returns whether `tokenId` exists.
     */
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _owners[tokenId] != address(0);
    }
}