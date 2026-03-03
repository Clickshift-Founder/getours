// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title CommissionDistributor
 * @author Global Exchange Tour
 * @notice Automates transparent payment splitting between GET, schools,
 *         referrers, and the Explorer Scholarship Fund.
 */
contract CommissionDistributor is AccessControl, ReentrancyGuard {

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    address payable public getWallet;
    address payable public explorerFundWallet;

    uint256 public scholarshipBps = 500;        // 5%
    uint256 public constant MAX_BPS = 10000;

    // =========== School Partners ===========
    struct SchoolPartner {
        string name;
        address payable wallet;
        uint256 commissionBps;
        bool isActive;
        uint256 totalEarned;
        uint256 totalRegistrations;
    }

    mapping(string => SchoolPartner) public schoolPartners;
    string[] public schoolCodes;

    // =========== Referrers ===========
    struct Referrer {
        address payable wallet;
        uint256 commissionBps;
        uint256 totalEarned;
        uint256 totalReferrals;
    }

    mapping(string => Referrer) public referrers;
    string[] public referralCodes;

    // =========== Payment Records ===========
    struct PaymentRecord {
        address payer;
        uint256 totalAmount;
        uint256 getShare;
        uint256 schoolShare;
        uint256 referrerShare;
        uint256 scholarshipShare;
        string schoolCode;
        string referralCode;
        string registrationId;
        uint256 timestamp;
    }

    PaymentRecord[] public paymentRecords;

    // Internal struct to keep stack depth manageable
    struct Splits {
        uint256 total;
        uint256 toGet;
        uint256 toSchool;
        uint256 toReferrer;
        uint256 toFund;
    }

    // =========== Metrics ===========
    uint256 public totalPaymentsProcessed;
    uint256 public totalRevenue;
    uint256 public totalSchoolCommissions;
    uint256 public totalReferrerCommissions;
    uint256 public totalScholarshipContributions;

    // =========== Events ===========
    event PaymentProcessed(
        uint256 indexed paymentId,
        address indexed payer,
        uint256 totalAmount,
        string registrationId
    );

    event PaymentDistributed(
        uint256 indexed paymentId,
        uint256 getShare,
        uint256 schoolShare,
        uint256 referrerShare,
        uint256 scholarshipShare
    );

    event SchoolPartnerAdded(string schoolCode, string name, address wallet, uint256 commissionBps);
    event ReferrerAdded(string referralCode, address wallet, uint256 commissionBps);
    event SchoolCommissionPaid(string schoolCode, uint256 amount);
    event ReferrerCommissionPaid(string referralCode, uint256 amount);

    // =========== Constructor ===========
    constructor(address payable _getWallet, address payable _explorerFundWallet) {
        require(_getWallet != address(0), "Invalid GET wallet");
        require(_explorerFundWallet != address(0), "Invalid fund wallet");

        getWallet = _getWallet;
        explorerFundWallet = _explorerFundWallet;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // =========== Partner Management ===========

    function addSchoolPartner(
        string calldata schoolCode,
        string calldata name,
        address payable wallet,
        uint256 commissionBps
    ) external onlyRole(ADMIN_ROLE) {
        require(wallet != address(0), "Invalid wallet");
        require(commissionBps <= 2000, "Commission too high (max 20%)");
        require(!schoolPartners[schoolCode].isActive, "School already exists");

        schoolPartners[schoolCode] = SchoolPartner({
            name: name,
            wallet: wallet,
            commissionBps: commissionBps,
            isActive: true,
            totalEarned: 0,
            totalRegistrations: 0
        });

        schoolCodes.push(schoolCode);
        emit SchoolPartnerAdded(schoolCode, name, wallet, commissionBps);
    }

    function addReferrer(
        string calldata referralCode,
        address payable wallet,
        uint256 commissionBps
    ) external onlyRole(ADMIN_ROLE) {
        require(wallet != address(0), "Invalid wallet");
        require(commissionBps <= 1000, "Commission too high (max 10%)");

        referrers[referralCode] = Referrer({
            wallet: wallet,
            commissionBps: commissionBps,
            totalEarned: 0,
            totalReferrals: 0
        });

        referralCodes.push(referralCode);
        emit ReferrerAdded(referralCode, wallet, commissionBps);
    }

    // =========== Payment Processing ===========

    function processPayment(
        string calldata registrationId,
        string calldata schoolCode,
        string calldata referralCode
    ) external payable nonReentrant {
        require(msg.value > 0, "Payment must be greater than 0");

        Splits memory s = _calcSplits(msg.value, schoolCode, referralCode);
        _sendSplits(s, schoolCode, referralCode);
        _record(s, registrationId, schoolCode, referralCode);
    }

    function _calcSplits(
        uint256 amount,
        string calldata schoolCode,
        string calldata referralCode
    ) internal returns (Splits memory s) {
        s.total = amount;
        s.toFund = (amount * scholarshipBps) / MAX_BPS;
        s.toGet = amount - s.toFund;

        if (bytes(schoolCode).length > 0 && schoolPartners[schoolCode].isActive) {
            SchoolPartner storage school = schoolPartners[schoolCode];
            s.toSchool = (amount * school.commissionBps) / MAX_BPS;
            s.toGet -= s.toSchool;
            school.totalEarned += s.toSchool;
            school.totalRegistrations++;
        }

        if (bytes(referralCode).length > 0 && referrers[referralCode].wallet != address(0)) {
            Referrer storage ref = referrers[referralCode];
            s.toReferrer = (amount * ref.commissionBps) / MAX_BPS;
            s.toGet -= s.toReferrer;
            ref.totalEarned += s.toReferrer;
            ref.totalReferrals++;
        }
    }

    function _sendSplits(
        Splits memory s,
        string calldata schoolCode,
        string calldata referralCode
    ) internal {
        (bool ok, ) = getWallet.call{value: s.toGet}("");
        require(ok, "GET payment failed");

        if (s.toSchool > 0) {
            (ok, ) = schoolPartners[schoolCode].wallet.call{value: s.toSchool}("");
            require(ok, "School payment failed");
            emit SchoolCommissionPaid(schoolCode, s.toSchool);
        }

        if (s.toReferrer > 0) {
            (ok, ) = referrers[referralCode].wallet.call{value: s.toReferrer}("");
            require(ok, "Referrer payment failed");
            emit ReferrerCommissionPaid(referralCode, s.toReferrer);
        }

        if (s.toFund > 0) {
            (ok, ) = explorerFundWallet.call{value: s.toFund}("");
            require(ok, "Scholarship fund payment failed");
        }
    }

    function _record(
        Splits memory s,
        string calldata registrationId,
        string calldata schoolCode,
        string calldata referralCode
    ) internal {
        uint256 pid = paymentRecords.length;

        paymentRecords.push(PaymentRecord({
            payer: msg.sender,
            totalAmount: s.total,
            getShare: s.toGet,
            schoolShare: s.toSchool,
            referrerShare: s.toReferrer,
            scholarshipShare: s.toFund,
            schoolCode: schoolCode,
            referralCode: referralCode,
            registrationId: registrationId,
            timestamp: block.timestamp
        }));

        totalPaymentsProcessed++;
        totalRevenue += s.total;
        totalSchoolCommissions += s.toSchool;
        totalReferrerCommissions += s.toReferrer;
        totalScholarshipContributions += s.toFund;

        emit PaymentProcessed(pid, msg.sender, s.total, registrationId);
        emit PaymentDistributed(pid, s.toGet, s.toSchool, s.toReferrer, s.toFund);
    }

    // =========== View Functions ===========

    function getDistributionMetrics() external view returns (
        uint256 _totalPayments,
        uint256 _totalRevenue,
        uint256 _totalSchoolCommissions,
        uint256 _totalReferrerCommissions,
        uint256 _totalScholarshipContributions
    ) {
        return (
            totalPaymentsProcessed,
            totalRevenue,
            totalSchoolCommissions,
            totalReferrerCommissions,
            totalScholarshipContributions
        );
    }

    function getSchoolPartner(string calldata schoolCode)
        external view returns (SchoolPartner memory)
    {
        return schoolPartners[schoolCode];
    }

    function getPaymentRecord(uint256 paymentId)
        external view returns (PaymentRecord memory)
    {
        require(paymentId < paymentRecords.length, "Invalid payment ID");
        return paymentRecords[paymentId];
    }

    function getPaymentCount() external view returns (uint256) {
        return paymentRecords.length;
    }

    function updateScholarshipRate(uint256 newBps) external onlyRole(ADMIN_ROLE) {
        require(newBps <= 1000, "Max 10%");
        scholarshipBps = newBps;
    }

    function updateGetWallet(address payable newWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newWallet != address(0), "Invalid wallet");
        getWallet = newWallet;
    }
}
