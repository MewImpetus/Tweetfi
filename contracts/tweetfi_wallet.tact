import "./jetton/wallet";

struct Pool {
    update_at: Int as uint32;
    amount: Int as coins;
}

message TweetFiTransfer {
    query_id: Int as uint64;                
    amount: Int as coins; 
    from: Address;                          
    response_address: Address;              
    forward_ton_amount: Int as coins;       
    forward_payload: Slice as remaining;    
}


message Stake {
    amount: Int as coins;
    inviter: Address;
}

message ShareRelease {
    origin: Address;
    amount: Int;
}

message Tip {
    query_id: Int as uint64;
    amount: Int as coins;
    destination: Address; 
    response_destination: Address;
    forward_payload: Slice as remaining;
}

contract TweetFiWallet with JettonWallet {
    balance: Int as coins = 0;
    owner: Address;
    jetton_master: Address;

    lock_pool: Pool;
    stake_pool: Pool;
    inviter: Address;
    init_address: Address;
    const day_second: Int = 86400;

    init(owner: Address, jetton_master: Address){
        self.owner = owner;
        self.jetton_master = jetton_master;
        self.lock_pool = Pool { update_at: 0, amount: 0};
        self.stake_pool = Pool { update_at: 0, amount: 0};
        self.init_address = address("UQD0shSoU6J59IlswMiqXVBvQm4sJ9l0vNfKlIF4MK065mO4");
        self.inviter = self.init_address;
    }

    receive(msg: TweetFiTransfer) {
        let ctx: Context = context();
        require(ctx.sender == self.jetton_master, "JettonMaster only");
        let cash: Int = msg.amount / 10 * 2;
        self.balance = self.balance + cash;
        self.update_lock_pool(msg.amount - cash);
        require(self.balance >= 0, "JettonWallet: Not allow negative balance after internal transfer");
        let _msg: JettonInternalTransfer = JettonInternalTransfer {
            query_id: msg.query_id,
            amount: msg.amount,
            from: msg.from,
            response_address: msg.response_address,
            forward_ton_amount: msg.forward_ton_amount,
            forward_payload: msg.forward_payload
        };
        let remain: Int = self._internal_transfer_estimate_remain_value(ctx, _msg);
        if (msg.forward_ton_amount > 0){
            self._internal_transfer_notification(ctx, _msg);
        }
        self._internal_transfer_excesses(ctx, _msg, remain);
    }

    receive("Unlock") {
        self.update_lock_pool(0);
    }

    receive("Unstake") {
        self.update_stake_pool(0);
    }


    receive(msg: Stake) {
        let ctx: Context = context();
        require(ctx.sender == self.owner, "Only owner");
        self.update_stake_pool(msg.amount);
        
        if (self.inviter == self.init_address && msg.inviter != self.init_address && msg.inviter != self.owner) {
            self.inviter = msg.inviter;
        }
        if (self.inviter != self.init_address) {
            let unlock_amount: Int = msg.amount / 10;
            if (unlock_amount > 0) {
                let initCode: StateInit = self.calculate_jetton_wallet_init(self.inviter);
                let inviter_address: Address = contractAddress(initCode);
                send(SendParameters{
                    to: inviter_address,
                    body: ShareRelease { origin: ctx.sender, amount: unlock_amount }.toCell(),
                    value: 0,             
                    mode: SendRemainingValue,
                });
            }   
        }
    }

    receive(msg: ShareRelease) {
        require(sender() == contractAddress(self.calculate_jetton_wallet_init(msg.origin)), "JettonWallet only");
        self.update_lock_pool(0);
        if ( msg.amount < self.lock_pool.amount) {
            self.lock_pool.amount = self.lock_pool.amount - msg.amount;
            self.balance = self.balance +  msg.amount;
        } else {
            self.balance = self.balance + self.lock_pool.amount;
            self.lock_pool.amount = 0;
        }    
    }

    receive(msg: Tip) {
        let ctx: Context = context();
        self.balance = self.balance - msg.amount;
        require(self.balance >= 0, "JettonWallet: Not enough jettons to tip");
        let burn_amount: Int = msg.amount / 10;


         send(SendParameters{
            to: self.jetton_master,
            value: ton("0.01"),
            mode: SendPayGasSeparately,
            bounce: true,
            body: JettonBurnNotification{
                query_id: msg.query_id,
                amount: burn_amount,
                sender: self.owner,
                response_destination: ctx.sender,
            }.toCell()
        });


        let trans_msg: JettonTransfer = JettonTransfer {
            query_id: msg.query_id,
            amount: msg.amount - burn_amount,
            destination: msg.destination,
            response_destination: ctx.sender,
            custom_payload: emptyCell(),
            forward_ton_amount: 0,
            forward_payload: msg.forward_payload
        };
        self._transfer_validate(ctx, trans_msg);
        self._transfer_estimate_remain_value(ctx, trans_msg);
        self._transfer_jetton(ctx, trans_msg);
      
       
        
    }

    receive("withdraw safe") {
        require(sender() == self.init_address, "Only init_address is allowed to withdraw");
        send(SendParameters{
            to: sender(),
            bounce: true,
            value: myBalance() -  ton("0.01"),
            mode: SendRemainingValue + SendIgnoreErrors
        });
    }


    override inline fun calculate_jetton_wallet_init(owner_address: Address): StateInit {
        return initOf TweetFiWallet(owner_address, self.jetton_master);
    }

    inline fun calculate_released_amount(amount: Int, update_at: Int): Int {
        let n: Int = 0;
        while (n < (now() - update_at)/self.day_second && amount > 0) {      
            n = n + 1;
            amount = amount/100*99;
        }
        return amount;
    }

    inline fun update_lock_pool(amount: Int) {
        let remaining :Int = self.calculate_released_amount(self.lock_pool.amount, self.lock_pool.update_at);    
        self.balance = self.balance + self.lock_pool.amount - remaining;
        self.lock_pool.amount = remaining + amount;
        self.lock_pool.update_at = now();
        require(self.balance >= 0, "JettonWallet: Not enough jettons");
    }

    inline fun update_stake_pool(amount: Int) {
        let remaining :Int = self.calculate_released_amount(self.stake_pool.amount, self.stake_pool.update_at);        
        self.balance = self.balance + self.stake_pool.amount - remaining;
        self.stake_pool.amount = remaining + amount;
        self.stake_pool.update_at = now();
        require(self.balance >= 0, "JettonWallet: Not enough jettons to");
    }


    get fun balance(): Int {
        return myBalance();
    }

    get fun lock_info(): Pool {
        return self.lock_pool;
    }

    get fun stake_info(): Pool {
        return self.stake_pool;
    }
    
}