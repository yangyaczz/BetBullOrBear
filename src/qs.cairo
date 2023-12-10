use starknet::ContractAddress;


#[derive(Drop, Copy, Serde)]
enum DataType {
    SpotEntry: felt252,
    FutureEntry: (felt252, u64),
    GenericEntry: felt252,
}

#[derive(Serde, Drop, Copy)]
struct PragmaPricesResponse {
    price: u128,
    decimals: u32,
    last_updated_timestamp: u64,
    num_sources_aggregated: u32,
    expiration_timestamp: Option<u64>,
}

#[derive(Serde, Drop)]
struct Checkpoint {
    timestamp: u64,
    value: u128,
    aggregation_mode: AggregationMode,
    num_sources_aggregated: u32,
}

#[derive(Serde, Drop, Copy)]
enum AggregationMode {
    Median: (),
    Mean: (),
    Error: (),
} 

#[derive(Serde, Drop, starknet::Store)]
struct BetDetail {
    user: ContractAddress,
    price: u128,
    direction: bool,
    amount: u256,
    end_timestamp: u64,
    claimed: bool,
}

#[starknet::interface]
trait IPragmaABI<TContractState> {
    fn get_data_median(self: @TContractState, data_type: DataType) -> PragmaPricesResponse;
    fn get_last_checkpoint_before(
        self: @TContractState,
        data_type: DataType,
        timestamp: u64,
        aggregation_mode: AggregationMode,
    ) -> (Checkpoint, u64);
    fn set_checkpoint(
        ref self: TContractState, data_type: DataType, aggregation_mode: AggregationMode
    );
}

#[starknet::interface]
trait HackTemplateABI<TContractState> {
    fn bet(ref self: TContractState, direction: bool, amount: u256, interval: u64);
    fn get_bet_detail(self: @TContractState, key: u64) -> BetDetail;
    fn check_win(self: @TContractState,bet_detail_id: u64) -> bool;
    fn claim(ref self: TContractState, bet_detail_id: u64);
    fn set_cp(ref self: TContractState);
    fn withdraw_fund(ref self: TContractState, amount: u256);
}

#[starknet::interface]
trait IERC20<TContractState> {
    fn name(self: @TContractState) -> felt252;
    fn symbol(self: @TContractState) -> felt252;
    fn decimals(self: @TContractState) -> u8;
    fn totalSupply(self: @TContractState) -> u256;
    fn balanceOf(self: @TContractState, account: ContractAddress) -> u256;
    fn allowance(self: @TContractState, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transferFrom(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;
}

#[starknet::contract]
mod HackTemplate {
    use super::{ContractAddress, HackTemplateABI, IPragmaABIDispatcher, IPragmaABIDispatcherTrait, PragmaPricesResponse, DataType, BetDetail, IERC20Dispatcher, IERC20DispatcherTrait, Checkpoint, AggregationMode};
    use array::{ArrayTrait, SpanTrait};
    use traits::{Into, TryInto};
    use starknet::{get_caller_address, get_contract_address, get_block_timestamp};
    use option::OptionTrait;

    const ETH_USD: felt252 = 19514442401534788;  // ETH/USD to felt252, can be used as asset_id

    #[storage]
    struct Storage {
        owner: ContractAddress,
        pragma_contract: ContractAddress,
        token: IERC20Dispatcher,
        id: u64,
        bet_detail: LegacyMap::<u64, BetDetail>,
        odd: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState, init_owner: ContractAddress, pragma_address: ContractAddress, token: ContractAddress) 
    {
        self.owner.write(init_owner);
        self.pragma_contract.write(pragma_address);
        self.token.write(IERC20Dispatcher { contract_address: token });
        self.id.write(0);
        self.odd.write(1500);  // 1500/1000 = 1.5
    }

    #[external(v0)]
    impl HackTemplateABIImpl of HackTemplateABI<ContractState> {

        fn bet(ref self: ContractState, direction: bool, amount: u256, interval: u64){

            // transfer bet amount to contract
            let caller = get_caller_address();
            let this = get_contract_address();
            self.token.read().transferFrom(caller, this, amount);

            let oracle_dispatcher = IPragmaABIDispatcher {
                contract_address: self.pragma_contract.read()
            };

            let output: PragmaPricesResponse = oracle_dispatcher
                .get_data_median(DataType::SpotEntry(ETH_USD));

 
            // bet detail
            let bet_struct = BetDetail {
                user: caller,
                price: output.price,
                direction: direction,
                amount: amount,
                end_timestamp: get_block_timestamp() + interval,
                claimed: false,
            };
            self.id.write(self.id.read() + 1);
            self.bet_detail.write(self.id.read(), bet_struct);
        }

        fn get_bet_detail(self: @ContractState, key: u64) -> BetDetail {
            let bet_detail = self.bet_detail.read(key);
            return bet_detail;
        }

        fn check_win(self: @ContractState,bet_detail_id: u64) -> bool{

            let bet_detail = self.bet_detail.read(bet_detail_id);
            assert(bet_detail.end_timestamp != 0, 'wrong bet detail id');

            let oracle_dispatcher = IPragmaABIDispatcher {
                contract_address: self.pragma_contract.read()
            };

            assert(get_block_timestamp() <= bet_detail.end_timestamp + 600, 'exceed timestamp');

            // let (checkpoint, timestamp) = oracle_dispatcher.get_last_checkpoint_before(DataType::SpotEntry(ETH_USD), bet_detail.end_timestamp, AggregationMode::Median(()));
            let output: PragmaPricesResponse = oracle_dispatcher
                .get_data_median(DataType::SpotEntry(ETH_USD));

            let final_price = output.price;
            let entry_price = bet_detail.price;
            
            if (bet_detail.direction == true) {
                if (final_price > entry_price) {
                    return true;
                } else {
                    return false;
                }
            } else {
                if (final_price > entry_price) {
                    return false;
                } else {
                    return true;
                }
            }
        }

        fn set_cp(ref self: ContractState) {
            let oracle_dispatcher = IPragmaABIDispatcher {
                contract_address: self.pragma_contract.read()
            };

            oracle_dispatcher.set_checkpoint(DataType::SpotEntry(ETH_USD), AggregationMode::Median(()));
        }

        fn claim(ref self: ContractState, bet_detail_id: u64) {
            let caller = get_caller_address();
            let bet_detail = self.bet_detail.read(bet_detail_id);
            assert(bet_detail.user == caller, 'not owner');

            assert(self.check_win(bet_detail_id), 'not win');

            assert(bet_detail.claimed == false, 'claimed');

            // change claimed to true
            let bet_struct = BetDetail {
                user : bet_detail.user,
                price: bet_detail.price,
                direction : bet_detail.direction,
                amount : bet_detail.amount,
                end_timestamp : bet_detail.end_timestamp,
                claimed : true,
            };

            self.bet_detail.write(bet_detail_id, bet_struct);

            // transfer reward
            self.token.read().transfer(caller, bet_detail.amount * self.odd.read() / 1000);
        }

        fn withdraw_fund(ref self: ContractState, amount: u256) {
            self.only_owner();
            self.token.read().transfer(self.owner.read(), amount);
        }
    }

    #[generate_trait]
    impl PrivateMethods of PrivateMethodsTrait {
        fn only_owner(self: @ContractState) {
            let caller = get_caller_address();
            assert(caller == self.owner.read(), 'Caller is not the owner');
        }
    }
}
