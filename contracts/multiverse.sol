// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;
import {ERC20mb} from "./ERC20mb.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Multiverse is ReentrancyGuard
{
	using SafeERC20 for IERC20;

	uint immutable TOKENS 					= 10**18;		//used both for token quantities and to scale numbers as to enable decimals
	uint immutable NOT_FOUND				= 10**18;		//used as a null value in for-loops that search
	uint immutable ONEDAY					= 86400;		//seconds
	uint immutable THREEDAYS 				= 3 * ONEDAY;
	uint immutable THIRTYDAYS 				= 30 * ONEDAY;
	uint immutable SIXTYDAYS 				= 60 * ONEDAY;
	uint immutable FORKTHRESHOLD			= TOKENS / 50;  //fraction of REP supply (2%) required to fork scaled to 10^18
	uint immutable MAX_OUTCOMES				= 9;			//set to the most outcomes that forkUniverse() can handle without hitting the gas limit
	uint immutable UNRESOLVED				= MAX_OUTCOMES;	//the starting value for outcome is UNRESOLVED. Outcome 0 is the first, outcome (MAX_OUTCOMES-1) is the last.
	uint immutable NO_REPORT				= MAX_OUTCOMES;	//the starting value for lastReport is NO_REPORT. 
	uint immutable BASE_FEE_RATE_OF_CHANGE	= (11 * TOKENS) / 10;	//base query fee is multiplied or divided by this every month. This value is 1.1*10^18, equal to 110%
	address immutable REPV2_ADDRESS 		= 0x221657776846890989a759BA2973e427DfF5C9bB;	// ### Change to the REP address created after the fork
	
	//Setup the universe structure which is universe[U].query[Q].stake[S].
	//										universe[U].auction[A].bid[B].
	//										universe[U].auction[A].rejectedPaymentsSumOfTop[K]
	//										universe[U].auction[A].rejectedAmountsSumOfTop[K]
	//										universe[U].auction[A].migrationToOutcome[O]
	struct Bid
	{	//Bids are in a doubly linked list to allow lazy insertion to the order book to save gas. The client looks up adjacent bids; contract validates.
		uint adjacentBetterBid;	// The ID of the bid that is closest in price to this bid and offers more ETH per REP. Set to NOT_FOUND if this is the highest bid.
		uint adjacentWorseBid;	// The ID of the bid that is closest in price to this bid and offers less ETH per REP. Set to NOT_FOUND if this is the lowest bid.
		address owner;			// The address of the account bidding for minted supply during a fork
		uint migrateTo; 		// The universe the REP the bidder recieves will automatically migrate to.
		uint repAmount;			// The quantity of REP the bidder wants to receive for the msg.value they sent. Scaled to 10^18.
		uint ethAmount;			// The quantity of ETH the bidder offered.
	}							
	struct Auction
	{	//the 3 auctions are auction[3], auction[4], auction[5]; the same as the forkState it happened during.
		uint nextBid;				// The next bid will be placed in this index number of bid[]
		uint bestBid;				// The bid that offers the most ETH per REP is bid[bestBid]. Set to NOT_FOUND if there are no bids.
		uint worstBid;				// The bid that offers the least ETH per REP is bid[worstBid]. Set to NOT_FOUND if there are no bids.
		uint mintAmount;			// The quantity of REP that will be sold in this auction.
		uint totalRepInBids;		// The quantity of REP that was bid for during this auction including rejected bids.
        Bid[] bid;  				// Put bid[B] inside of auction[A]. Each Auction has its own set of bids.
		//put migrationToOutcome[O] inside of auction[A]. The total amount migrated to each outcome among winning bids.
		uint[] migrationToOutcome;	
		//put rejectedPaymentsSumOfTop[K] inside of auction[A]. e.g....Top[1] is the sum of the ETH payments in the two highest price rejected bids.		
		uint[] rejectedPaymentsSumOfTop;
		// Put rejectedAmountsSumOfTop[K] inside of auction[A]. e.g...Top[1] is the sum of the REP amounts in the two highest price rejected bids.
		uint[] rejectedAmountsSumOfTop;
	}
	struct Stake
	{
		address owner;	// The address of the reporter that placed this stake
		uint claim;		// The outcome this reporter staked on. [0,INVALID]
		uint amount;	// The amount staked on this outcome
		uint time;		// The unix timestamp when this stake was placed.
	}
    struct Query
	{
        uint fee;			// Quantity of universe.repAddress that was paid to create this query. Is also the initial stake required to report.
		address tipToken;	// Set by Query creator. The ERC20 that tips for the reporter must be paid using.
		uint tip;			// Total quantity of universe.query.tipToken that was donated. Augments reporter pay.
        uint createTime;	// Unix timestamp
        string question;	// A multiple choice question about anything.
		uint numberOfOutcomes;//How many outcomes reporters are allowed to choose from including the invalid outcome. [3,MAX_OUTCOMES].
        uint outcome;		// The final outcome used by customers. Starts at UNRESOLVED.
        uint lastReport;	// The outcome that was most recently reported. Starts at NO_REPORT.
		uint timeOfLastReport;//Unix timestamp of the most recent report.
        uint lastStake;		// Quantity of universe.repAddress most recently staked by a reporter on this query
        uint totalStake;	// Quantity of universe.repAddress in total staked by reporters on this query
		uint nextStake;		// The id of the next open slot for staking. Starts at 0. 
        Stake[] stake;  		// Put stake[S] inside of query[Q]. Each Query has its own set of stakes.
    }
    struct Universe
	{
        uint forkState;         // 0=not forking, 1=awaiting children, 2=initial migration, 3=supply restoration(SR)1, 4=SR2, 5=SR3, 6=post-fork, 7=forming
		uint forkQuery;			// the query ID that caused a fork. Placing a fork bond changes this from 0 to the query ID that the fork bond was staked on.
        address repAddress;     // The REP address for this universe
		uint supplyBeforeFork;	// The totalSupply() of the REP token for this universe at the time a fork was triggered. Used to restore the supply after migration.
		uint parent;            // The ID of the universe that forked to create this one.
        uint favoriteChild;     // The ID of the universe that won the forking game when this universe forked. During a fork it is set to the tentative winner.
		uint heir;				// The ID of the universe that this one forwards all transactions to. Progression: [self]>>[favoriteChild]>>[favoriteGrandchild]>>[etc]
        address queryTokenizer; // The address of the contract that manages query tokens. This address is allowed to pay a different price to create a Query.
        uint baseFee;           // baseFee * priceModifier = queryFee. Starts at 10 REP in universe 0, otherwise inherited from parent.
        bool baseFeeIncreased;  // Did the baseFee increase during the last change? 1 or 0
		uint timeFeeLastChanged;// The unix timestamp of the last time the baseFee was updated
		uint totalFeeHoldings;	// The total amount of REP this universe has allocated to Query fees. Increases when Query is purchased, decreases the same amount at resolution.
        uint[] threeDayRevenue;	// tracks revenue for each ~3 day span of query creation times starting with threeDayRevenue[0] 
        uint[] threeDayProfit;	// tracks profit for each ~3 day span of query creation times. starting with threeDayProfit[0]
		uint totalRevenue;		// tracks total revenue. Due to fake front-loaded revenue, actual revenue is this minus 600.
		uint totalProfit;		// tracks total profit. Due to fake front-loaded profit, actual profit is this minus 400.
        Query[] query;			// Put query[Q] inside of universe[U]. Each universe has its own set of queries that begin to differ after a fork.
        Auction[] auction;		// Put auction[A] inside of universe[U]. Each universe has its own set of auctions that do not copy over during a fork.
		uint nextQuery;			// Keeps track of the next empty query slot. The next new query will get this ID number
    }

    Universe[] public universe;	//enables multiple universes of data in the format universe[U].

    constructor()
	{	//Set starting values for the first universe, universe 0	
		universe.push();									//create a new universe. It will receive ID 0.
		universe[0].repAddress 			= REPV2_ADDRESS;	//set the first universe REP address to the address of REP V2
		universe[0].queryTokenizer 		= createQueryTokenizer(0);	//create the query tokenizer for universe 0 and store the resulting address
		universe[0].baseFee 			= 10*TOKENS;		//start the baseFee at 10 REP
		universe[0].parent				= NOT_FOUND;		//Used by createREP to know when to stop looping through forking history.
		universe[0].timeFeeLastChanged 	= block.timestamp;	//set the last fee change to now, this gives one month after deployment before the fee changes again.
		universe[0].nextQuery 			= 1; 				//starting at 1 avoids negative numbers in the code and enables query[0] to log the creation time of the multiverse.
		universe[0].query.push();							//create a new query. It will receive ID 0.
		universe[0].query[0].createTime = block.timestamp;	//set to the creation time of the first universe to now so the fee controller knows when time starts. All other query params are 0.
		for (uint i = 0; i < 20; i++)	//set 60 days of fake activity (one query per day) to bootstrap the fee controller. 3day number 20 will start empty.
		{		
			universe[0].threeDayRevenue.push();				//create a new revenue data storage slot. It will receive ID i.	
			universe[0].threeDayProfit.push();				//create a new revenue data storage slot. It will receive ID i.
			universe[0].threeDayRevenue[i] 	 				= 3*universe[0].baseFee;
			universe[0].totalRevenue 					   += 3*universe[0].baseFee;
			universe[0].threeDayProfit[i] 	 				= 2*universe[0].baseFee;	//this sets fake profit to 2/3 of fake revenue
			universe[0].totalProfit 					   += 2*universe[0].baseFee;
		}
	}

    function forkUniverse(uint parent) public
	{	//Split a universe into one copy for every outcome. Advances from forkState 1 to 2.
		// 	after a fork bond is placed, forkState is set to 1, freezing the system.
		//	however, the forking game (migration) does not begin until someone calls this function
		require(universe[parent].forkState 	== 1, 			"Error: To fork a universe it must be in fork state 1: awaiting children");	
		
		//Set shorter variables for readability
		uint firstFork			= universe.length;	//length is the number of universes which is the same number as the next available universe ID.
		uint forkQuery 			= universe[parent].forkQuery;
		uint numberOfOutcomes 	= universe[parent].query[forkQuery].numberOfOutcomes;
		uint current3day 		= _current3day();
		uint numberOfForkStakes;
		uint thisStake;
		uint i;
		uint n;
		
		//Create a universe for each outcome. Copying all Queries would exceed the gas limit and they are instead copied over later on demand by importQuery()
		for (n=0; n<numberOfOutcomes; n++)
		{
			universe.push();																//create a new universe
			universe[firstFork+n].forkState 		= 7;									// universe state = forming
			universe[firstFork+n].parent 			= parent;								//set this universe parent to the user provided parent
			universe[firstFork+n].repAddress		= createREP(firstFork+n);				//create an erc20 for this index and set the returned address
			universe[firstFork+n].heir				= firstFork+n;							//the heir starts as self (no forwarding of transactions initially)
			universe[firstFork+n].queryTokenizer 	= createQueryTokenizer(firstFork+n);	//create the query tokenizer contract and set the returned address
			universe[firstFork+n].baseFee 			= universe[parent].baseFee;				//inherit the baseFee from parent
			universe[firstFork+n].baseFeeIncreased 	= universe[parent].baseFeeIncreased;	//inherit the baseFeeIncreased from parent
			universe[firstFork+n].timeFeeLastChanged= universe[parent].timeFeeLastChanged;	//inherit the time that the baseFee last changed
			universe[firstFork+n].totalFeeHoldings 	= universe[parent].totalFeeHoldings;	//inherit the totalFeeHoldings from parent
			universe[firstFork+n].nextQuery 		= universe[parent].nextQuery;			//inherit the next available query slot from parent
			universe[firstFork+n].totalRevenue 		= universe[parent].totalRevenue;		//inherit the total revenue from parent
			universe[firstFork+n].totalProfit	 	= universe[parent].totalProfit;			//inherit the total revenue from parent
			//Inherit profit and revenue storage space. For each storage slot in parent, push() to create one in the current fork (firstFork+n)
			for (i=0; i<universe[parent].threeDayProfit.length; i++) 	universe[firstFork+n].threeDayProfit.push();
			for (i=0; i<universe[parent].threeDayRevenue.length; i++) 	universe[firstFork+n].threeDayRevenue.push();
			//Inherit recent profit and revenue history from parent
			for (i=0; i<20; i++)
			{	//For the last 20 three day periods (60 days), copy over profit and revenue data. Only 60 days is copied because the oldest financial data the protocol references is 60 days old.
				universe[firstFork+n].threeDayProfit[current3day-i] 	= universe[parent].threeDayProfit[current3day-i];
				universe[firstFork+n].threeDayRevenue[current3day-i] 	= universe[parent].threeDayRevenue[current3day-i];
			}
			//inherit query storage. for the number of queries on parent create empty query slot on firstFork+n
			for (i=0; i<universe[parent].query.length; i++) 	universe[firstFork+n].query.push(); 
			//Copy over the fork query since it will be interacted with during the forking game. Done one parameter at a time because the stake subobject prevents a one-liner:
			universe[firstFork+n].query[forkQuery].createTime 	= universe[parent].query[forkQuery].createTime;
			universe[firstFork+n].query[forkQuery].question 	= universe[parent].query[forkQuery].question;
			universe[firstFork+n].query[forkQuery].outcome 		= universe[parent].query[forkQuery].outcome;
			universe[firstFork+n].query[forkQuery].lastReport	= universe[parent].query[forkQuery].lastReport;
			universe[firstFork+n].query[forkQuery].lastStake 	= universe[parent].query[forkQuery].lastStake;
			universe[firstFork+n].query[forkQuery].totalStake	= universe[parent].query[forkQuery].totalStake;
			universe[firstFork+n].query[forkQuery].fee 			= universe[parent].query[forkQuery].fee;
			universe[firstFork+n].query[forkQuery].nextStake 	= universe[parent].query[forkQuery].nextStake;
			//Inherit tipToken and tip. Note that if the tip token is REP the tip will become worthless (it wont migrate or split).
			universe[firstFork+n].query[forkQuery].tipToken 	= universe[parent].query[forkQuery].tipToken;
			universe[firstFork+n].query[forkQuery].tip 			= universe[parent].query[forkQuery].tip;
			//Copy over the stakes of the query that caused the fork.
			numberOfForkStakes									= universe[parent].query[forkQuery].stake.length;
			universe[firstFork+n].query[forkQuery].stake		= new Stake[](numberOfForkStakes);	//create storage space for fork query stakes. Same size as parent.
			for (thisStake = 0; thisStake < numberOfForkStakes; thisStake++)
				universe[firstFork+n].query[forkQuery].stake[thisStake] = universe[parent].query[forkQuery].stake[thisStake];
		}
		//split all of the parent's query fees into each universe. Enables reporters to get paid in each universe for inherited Queries.
		split(parent, firstFork, universe[parent].totalFeeHoldings);
		//split the REP staked on the fork query into each universe. Enables forking game payoffs in each universe.
		split(parent, firstFork, universe[parent].query[forkQuery].totalStake);
		universe[parent].forkState 						= 2; 					//the parent changes from awaiting children to initial migration
    }
	
	function split(uint _parent, uint _firstFork, uint _amount) private
	{	//Split REP into every fork. Only REP stored in query fees or staked on the fork query will split instead of migrate.
		//requires are not needed because this function is private.
		//split() is only called by forkUniverse()
		//Lookup the number of universes to split into
		uint forkQuery			= universe[_parent].forkQuery;
		uint numberOfOutcomes	= universe[_parent].query[forkQuery].numberOfOutcomes;
		//transfer an _amount of [_parent].repAddress from this contract to the burn address
		ERC20mb(universe[_parent].repAddress).burn(_amount);
		//mint this same _amount in each fork and give it to this contract
		for (uint i=0; i<numberOfOutcomes; i++)
		{
			ERC20mb(universe[_firstFork+i].repAddress).mint(address(this), _amount);
		}
	}
	
	function migrate(uint _destination, uint _amount) public
	{	//Migrate an _amount of REP to a _destination universe
		//	migrates an _amount of the msg.senders erc20 on the parent erc20 of the destination to to the erc20 of the _destination.
		//	this function is for REP holders to migrate.
		//	during initial migration all REP is required to migrate including REP staked on queries other than the subject of the fork
		//	the only REP that splits instead of migrates is in Query Fees and staked on the fork query.
		require(universe[_destination].repAddress != address(0), "Error: The destination universe must exist");
		uint forkState = universe[universe[_destination].parent].forkState;	//sets forkState to the parent universe fork state.
		//only forkState 2 is allowed. The other migration that happens in forkState 3 to 5 is built into the function to claim proceeds from the auction.
		//	the forkState stays as 2 until someone calls createBid() after 
		require(forkState == 2, "Error: Migration is only allowed when the parent of the destination is in fork state 2: initial migration");
		//import the ERC20 token of the _destination
		ERC20mb destination = ERC20mb(universe[_destination].repAddress);
		//import the ERC20 token of the parent of the _destination
		ERC20mb parent 		= ERC20mb(universe[universe[_destination].parent].repAddress);
		require(parent.balanceOf(msg.sender) >= _amount, "Error: The amount parameter exceeds your balance of the destination's parent's REP token");
		//transfer an _amount of parent from message sender to burn address
		parent.burnFrom(msg.sender, _amount);
		//mint the same _amount of destination and give it to the message sender
		destination.mint(msg.sender, _amount);
	}
	
	function _queryFee(uint _universe, uint _queryNearly3DaysAgo, uint _queryNearly60DaysAgo) public returns(uint queryFee)
	{	//Returns the query fee, if it is time for the fee to change, it also calls change_queryFee().
		//	To save gas, the client is required to look up the oldest query <3 days old, the oldest that is <60 days old, and instead the most recent if none exist
		//require the universe exists by checking if it has a REP token
		require(universe[_universe].repAddress != address(0), "Error: The provided universe does not exist");
		//all txs are forwarded to the heir. Heir is self until fork, afterwards txs are forwarded to winners of the forking games.
		uint u = universe[_universe].heir;
		//shorter variables for readability
		uint currentTime		= block.timestamp;
		uint nextQuery			= universe[u].nextQuery;
		uint lastQuery			= nextQuery - 1;	//nextQuery starts at 1 in a new universe so this cant go negative.
		uint timeOfLastQuery	= universe[u].query[lastQuery].createTime;
		uint threeDayVolume;
		uint sixtyDayVolume;
		uint volumeRatio;	//this number divided by TOKENS (10^18) is the ratio. e.g. 0.7 * 10^18 = 70% volume ratio
		//if the last query created has no create time, it means a fork happened and it needs to be imported.
		if (timeOfLastQuery == 0)	importQuery(u,lastQuery);
		if (currentTime - THREEDAYS > timeOfLastQuery)		//if no queries were created in the last 3 days
			_queryNearly3DaysAgo = lastQuery;	//set the nearly3DaysAgo query to the last query.
		else									//otherwise verify the client provided the oldest query
		{	//if there is no create time for the query created just before the alleged nearly 3 day old query, it means a fork happened and it needs to be imported.
			if (universe[u].query[_queryNearly3DaysAgo-1].createTime == 0)	importQuery(u,_queryNearly3DaysAgo-1);
			//require the client correctly identified the oldest by checking if one query earlier is less than 3 days old. 
			require(currentTime - THREEDAYS > universe[u].query[_queryNearly3DaysAgo-1].createTime, "Error: The Query ID you provided is not the oldest in the last 3 days");
		}
		if (currentTime - SIXTYDAYS > timeOfLastQuery)		//if no queries were created in the last 3 days
			_queryNearly60DaysAgo = lastQuery;	//set the nearly3DaysAgo query to the last query.
		else									//otherwise verify the client provided the oldest query
		{	//if there is no create time for the query created just before the alleged nearly 60 day old query, it means a fork happened and it needs to be imported.
			if (universe[u].query[_queryNearly60DaysAgo-1].createTime == 0)	importQuery(u,_queryNearly60DaysAgo-1);
			//require the client correctly identified the oldest by checking if one query earlier is less than 60 days old. 
			require(currentTime - SIXTYDAYS > universe[u].query[_queryNearly60DaysAgo-1].createTime, "Error: The Query ID you provided is not the oldest in the last 60 days");
		}
		//Update the Query Fee
		if (currentTime - THIRTYDAYS > universe[u].timeFeeLastChanged && universe[u].forkState == 0)
		{	//if it has been longer than a month since the fee changed and not in a fork
			changeQueryFee(u);
		}
		//these variables are set after the requires because the above code sometimes modifies _queryNearly3DaysAgo and _queryNearly60DaysAgo
		threeDayVolume = nextQuery - _queryNearly3DaysAgo;	//these two volume counts are always greater than 0 because nextQuery has a larger ID number than any existing query.
		sixtyDayVolume = nextQuery - _queryNearly60DaysAgo;	
		//calculate the normalized ratio of the number of queries created in the last 3 days to the number created in the last 60 days. Scaled to 10^18 (TOKENS)
		//when there is no volume in the last 3 days, the volume ratio will be 1 / sixtyDayVolume. When no volume in last 60 days it will be 1/1=1
		volumeRatio = ((threeDayVolume * 20) * TOKENS) / sixtyDayVolume;

		queryFee = (universe[u].baseFee * _feeModifier(volumeRatio)) / TOKENS;		
		
	}

	function _feeModifier(uint volumeRatio) public pure returns(uint feeModifier)
	{	//takes in the volume ratio (recent/historic query creation) and outputs the query fee modifier. Only used by _queryFee()
		uint shortage;
		uint powered;
		uint denominator;
		uint i;
		
		if (volumeRatio >= 1 * TOKENS)	
		{	//if the volume recently increased, increase the fee by 20% of the increase
			feeModifier = (4*TOKENS)/5 + volumeRatio/5;
		}
		else
		{	//Apply a formula that decreases the fee slightly for up to ~25% drops, and dramatically thereafter.
			//the original formula for when volumeRatio<1 is feeModifier = 1 / (1 + 100(1-volumeRatio)^6) , however this is not scaled to TOKENS and even when scaled causes overflow.
			//to avoid this issue, the modifier is calculated iteratively
			//Let shortage = 1-volumeRatio so that the formula is now:
			//		feeModifier = 1 / (1 + 100(shortage)^6)
			shortage = TOKENS - volumeRatio;	//the decline in volume is 1-(volumeRatio/10^18). Scaled to 10^18 (TOKENS) is: TOKENS - volumeRatio		
			//Let powered = (shortage)^6 so that the formula is now:
			//		feeModifier = 1 / (1 + 100*powered)
			powered = TOKENS;	//powered starts at 1 scaled to 10^18
			for (i=0; i<6; i++)
			{
				//powered is then repeatedly multiplied by shortage. As both are scaled to 10^18, it must be divided by TOKENS to keep the same scale.
				powered = (powered * shortage) / TOKENS;	
			}
			//Let denominator = 1 + 100*powered so that the formula is now:
			//		feeModifier = 1 / denominator
			denominator = TOKENS + (100 * powered);
			//because the denominator is scaled up, instead of scaling it back down we scale up the numerator for better accuracy.
			feeModifier = (TOKENS * TOKENS) / denominator; //this number divided by TOKENS (10^18) is the modifier. e.g. 0.01*10^18 = The query fee is reduced to 1% of the baseFee.
		}
		
	}

	function changeQueryFee(uint u) private
	{	//Changes the Query Fee to increase profit. Only called by _queryFee() when it is time for the fee to change
		//set shorter variables
		bool baseFeeIncreased 			= universe[u].baseFeeIncreased;
		uint[] memory threeDayRevenue	= universe[u].threeDayRevenue;    //an array of uint revenue buckets
		uint[] memory threeDayProfit	= universe[u].threeDayProfit;    //an array of uint revenue buckets
		uint baseFee 					= universe[u].baseFee;
		uint totalProfit				= universe[u].totalProfit;
		uint totalRevenue				= universe[u].totalRevenue;
		uint current3day 				= _current3day();
		uint currentTime				= block.timestamp;
		uint thisMonthProfit;
		uint thisMonthRevenue;
		uint previousMonthRevenue;
		uint previousMonthProfit;
		uint profitMargin;	//scaled to 10^18
		uint i;

		//Calculate the revenue during this month, skipping the current3day because it is not completed yet.
		for (i=1; i<11; i++)
		{
			thisMonthRevenue 	+= threeDayRevenue[current3day-i];
		}
		//Calculate the revenue during the previous month
		for (i=11; i<21; i++)
		{
			previousMonthRevenue += threeDayRevenue[current3day-i];
		}			
		//Calculate the profit during the previous month
		for (i=11; i<21; i++)
		{
			previousMonthProfit += threeDayProfit[current3day-i];
		}	
		//estimate profit margin using previous month profit and revenue
		//profit margin is scaled to 10^18 represented by TOKENS to enable decimals
		profitMargin	= (previousMonthProfit * TOKENS) / previousMonthRevenue;
		//stablize the profitMargin by averaging the short term calculated above with the all time profitMargin.
		profitMargin	= (profitMargin + (totalProfit * TOKENS) / totalRevenue) / 2;
		//estimate this months profit using profit margin
		thisMonthProfit = (thisMonthRevenue * profitMargin) / TOKENS;	//divided by 10^18 to remove scaling
		if (thisMonthProfit > previousMonthProfit)
		{
			if(baseFeeIncreased)	//if profit increased after the fee was increased
			{
				baseFee = (baseFee * BASE_FEE_RATE_OF_CHANGE) / TOKENS;		//further increase the fee
			}
			else					//if profit increased after the fee was decreased
			{
				baseFee = (baseFee * TOKENS) / BASE_FEE_RATE_OF_CHANGE;		//further reduce the fee
			}
		}
		else
		{
			if(baseFeeIncreased)	//if profit decreased after the fee was increased
			{
				baseFee = (baseFee * TOKENS) / BASE_FEE_RATE_OF_CHANGE;		//undo the increase
				baseFeeIncreased = false;
			}
			else					//if profit decreased after the fee was decreased
			{
				baseFee = (baseFee * BASE_FEE_RATE_OF_CHANGE) / TOKENS;		//undo the decrease
				baseFeeIncreased = true;
				}
		}	
		//save the new state
		universe[u].baseFeeIncreased 	= baseFeeIncreased;
		universe[u].timeFeeLastChanged	= currentTime;
		universe[u].baseFee 			= baseFee;
	}

	function createQuery(
		//to save gas, the client is required to look up the oldest query <3 days old, the oldest that is <60 days old, and if none exist, either the most recent or left blank(0).
		uint _universe,	//the universe to create a query in. If Augur has never been successfully attacked use 0.
		string calldata question,	//A multiple choice question. If the question is true/false 0 is false and 1 is true.
									//	to prevent ambiguity, the UI will not assume 0 is false. The UI will show numbers instead of text unless [0=false,1=true] is appended.
									//	if categorical, include outcome descriptions by appending text in this format: [0=Apple,1=Bannana,2=Carrot] 
		uint numberOfOutcomes,	//The number of outcomes + 1 for invalid. A true/false question has 3 outcomes.
		uint _queryNearly3DaysAgo,	//The id of a query that is less than 3 days old where the query before it is greater than 3 days old. If none, set to 0.
		uint _queryNearly60DaysAgo,	//The id of a query that is less than 60 days old where the query before it is greater than 60 days old. If none, set to 0.
		address tipToken,				//Any ERC20 can be set as the tip token. 
		uint optionalFee				//Normally set to 0. This is only used by the Query Tokenizer to declare its own Query Fee.
		) public
	{	//Ask the oracle a question.
		require(universe[_universe].repAddress != address(0), "Error: The universe you provided does not exist");
		//all txs are forwarded to the heir. Heir is self until fork, afterwards txs are forwarded to winners of the forking games.
		uint u 				= universe[_universe].heir;
		//Set shorter variables
		uint queryFee;
		uint thisQuery		= universe[u].nextQuery;	//the id this query will get is the next available query id.
		uint current3day	= _current3day();			//the time slot that revenue and profit data will be saved to
		uint currentTime	= block.timestamp;
		address buyer		= msg.sender;
		
		require(universe[u].forkState == 0 || universe[u].forkState == 7, "Error: Forking universes do not allow Queries to be created");
		require(numberOfOutcomes > 2, 				"Error: The number of outcomes must be at least 3 to allow for a binary choice and invalid");
		require(numberOfOutcomes <= MAX_OUTCOMES, 	"Error: The number of outcomes is more than this blockchain supports during forkUniverse()");
		//import this universes REP token functions into rep.
		ERC20mb rep = ERC20mb(universe[u].repAddress);
		if (msg.sender == universe[u].queryTokenizer)
		{	//if the contract that called this function is the Query Tokenizer contract
			queryFee 	= optionalFee;	//the query tokenizer contract decides its own query fee
			buyer 		= universe[u].queryTokenizer;	//and is the one who pays for it
		}
		else//set the query fee normally
		{
			queryFee = _queryFee(u, _queryNearly3DaysAgo, _queryNearly60DaysAgo);
		}
		require(rep.balanceOf(buyer) >= queryFee, 	"Error: You have do not have enough REP in that universe to cover the Query Fee");
		//transfer the Query Fee from the buyer to this contract
		rep.transferFrom(buyer, address(this), queryFee);		
		//Save the Query	
		universe[u].query.push();						//create storage space for a new query
		//while the number of threeday revenue storage slots is less than or equal to the current slot data should be stored to, add an additional storage slot with push().
		while(universe[u].threeDayRevenue.length<=current3day) universe[u].threeDayRevenue.push();
		universe[u].query[thisQuery].fee				= queryFee;
		universe[u].query[thisQuery].tipToken			= tipToken;
		universe[u].query[thisQuery].createTime	 		= currentTime;
		universe[u].query[thisQuery].question			= question;
		universe[u].query[thisQuery].numberOfOutcomes	= numberOfOutcomes;
		universe[u].query[thisQuery].outcome			= UNRESOLVED;
		universe[u].query[thisQuery].lastReport			= NO_REPORT;
		universe[u].nextQuery 						   += 1; //move to the next available query id.
		universe[u].totalFeeHoldings		 		   += queryFee; //keep track of fees held
		universe[u].threeDayRevenue[current3day]	   += queryFee; //keep track of revenue
		universe[u].totalRevenue					   += queryFee; //keep track of revenue
	}

	function tip(uint _universe, uint query, uint amount) public nonReentrant
	{	//Add a tip for the Reporter
		require(universe[_universe].repAddress != address(0), 		"Error: The universe you provided does not exist");
		//all txs are forwarded to the heir. Heir is self until fork, afterwards txs are forwarded to winners of the forking games.
		uint u = universe[_universe].heir;
		require(query < universe[u].nextQuery, 					"Error: The query you provided does not exist");
		//if the query should have data because query<nextQuery but has no createTime, it means there was a fork and this query still needs to be imported from parent.
		if (universe[u].query[query].createTime == 0)	importQuery(u,query);
		require(universe[u].query[query].outcome == UNRESOLVED, "Error: Resolved queries can not be tipped");
		//import this queries tip token functions into tipToken.
		IERC20 tipToken = IERC20(universe[u].query[query].tipToken);
		require(tipToken.balanceOf(msg.sender) >= amount, 		"Error: You do not have this amount of this queries tip token");
		//measure balance before because we do not trust the arbitrary ERC20 to transfer the requested amount.
		uint balanceBefore 	= tipToken.balanceOf(address(this));
		//transfer an amount of tipToken from message sender to this contract
		tipToken.transferFrom(msg.sender, address(this), amount);
		//change the amount to what was actually recieved
		amount 	= tipToken.balanceOf(address(this)) - balanceBefore;
		//increase the total tip by the amount
		universe[u].query[query].tip += amount;
	}
	
	function report(uint _universe, uint query, uint _report) public
	{	//Report an outcome
		require(universe[_universe].repAddress != address(0),		"Error: The universe you provided does not exist");
		//all txs are forwarded to the heir. Heir is self until fork, afterwards txs are forwarded to winners of the forking games.
		uint u = universe[_universe].heir;
		require(query < universe[u].nextQuery, 					"Error: The query you provided does not exist");
		//if the query should have data because query<nextQuery but it has no createTime, it means there was a fork and this query still needs to be imported.
		if (universe[u].query[query].createTime == 0)	importQuery(u,query);
		require(universe[u].forkState 			!= 1, 			"Error: Reporting is not allowed during a fork");
		require(universe[u].forkState 			!= 2, 			"Error: Reporting is not allowed during a fork");
		require(universe[u].forkState 			!= 3, 			"Error: Reporting is not allowed during a fork");
		require(universe[u].forkState 			!= 4, 			"Error: Reporting is not allowed during a fork");
		require(universe[u].forkState 			!= 5, 			"Error: Reporting is not allowed during a fork");
		require(universe[u].forkState 			!= 6, 			"Bug: This transaction should have been forwarded to heir");
		require(universe[u].query[query].outcome== UNRESOLVED, 	"Error: Resolved queries can not be reported on");
		//import this universes REP token as rep.
		ERC20mb rep 			= ERC20mb(universe[u].repAddress);
		//Create shorter variables for readability:
		uint requiredStake;
		uint currentTime		= block.timestamp;
		uint fee 				= universe[u].query[query].fee;
		uint numberOfOutcomes	= universe[u].query[query].numberOfOutcomes;
		uint lastReport			= universe[u].query[query].lastReport;
		uint lastStake			= universe[u].query[query].lastStake;
		uint totalStake			= universe[u].query[query].totalStake;
		uint thisStake			= universe[u].query[query].nextStake;
		uint forkBond			= (FORKTHRESHOLD * rep.totalSupply()) / TOKENS;	//Both are scaled by 10^18 so they must be divided by 10^18 after multiplying to retain scale.
		require(_report != lastReport, 		"Error: You must report an outcome different than the last reporter");
		require(_report < numberOfOutcomes, 	"Error: Your report is not one of the outcome choices for this Query");
		//Determine the required stake
		if (lastStake == 0)
		{	//if no one has reported yet, the initial reporting bond is the same as the query fee paid for this query.
			requiredStake = fee;
		}
		else
		{	//if it is an appeal, the reporting bond is double the previous bond.
			requiredStake = lastStake * 2;
		}
		//if the required stake is greater than half the forkBond the requiredStake becomes the forkBond
		if (requiredStake >= forkBond / 2)
		{
			requiredStake = forkBond;
		}
		require(rep.balanceOf(msg.sender) >= requiredStake, "Error: You do not have enough of this universes REP to report");
		//transfer requiredStake from message sender to this contract
		rep.transferFrom(msg.sender, address(this), requiredStake);
		//update variables
		lastReport 				= _report;
		lastStake			 	= requiredStake;
		totalStake			   += requiredStake;
		//Save the variables
		universe[u].query[query].lastReport 			= lastReport;
		universe[u].query[query].lastStake 				= lastStake;
		universe[u].query[query].totalStake 			= totalStake;
		universe[u].query[query].nextStake				= thisStake+1;
		universe[u].query[query].timeOfLastReport		= currentTime;
		universe[u].query[query].stake.push();			//create storage slot for this stake
		universe[u].query[query].stake[thisStake].owner	= msg.sender;
		universe[u].query[query].stake[thisStake].claim	= _report;
		universe[u].query[query].stake[thisStake].amount= requiredStake;
		universe[u].query[query].stake[thisStake].time	= currentTime;
		//If this report triggered a fork 
		if (requiredStake == forkBond)
		{	//change into a forking state over this query.
			universe[u].forkState 			= 1; //awaiting children
			universe[u].forkQuery			= query;
			universe[u].supplyBeforeFork 	= rep.totalSupply();
		}
	}
	
	function importQuery(uint _universe, uint query) private
	{	//Import a query from its parent universe (or parents parent etc) after a fork
		//	this function exists because copying all queries during a fork costs too much gas, so they are copied as needed later
		// 	no requires because this is a private function that should only be called internally
		//Shorten variables for readability
		uint origin;
		uint u = _universe;
		uint q = query;
		//search for the universe this query originated from
		//	starting with parent, continue looking up parents until the createTime for this query is nonzero.
		//	this loop is unbounded but in the unusual incident where a query is revived after many forks,
		//	being unbounded allows the user to spend as much gas as they want importing the query.
		//	(first consider parent as origin ; then for as long as query createTime is 0; instead try the parent's parent )
		for (origin = universe[u].parent; universe[origin].query[q].createTime == 0; origin = universe[origin].parent){}
		
		//Copy over the query data one value at a time:
		//	stake[], nextStake,totalStake, lastStake, timeOfLastReport are all not copied over because a fork happened and all stakes were withdrawn or lost.
		//while the number of query storage slots in this universe is less than the origin universe, create a new storage slot with push().
		while(universe[u].query.length<universe[origin].query.length)	universe[u].query.push();
		universe[u].query[q].createTime			= universe[origin].query[q].createTime;
		universe[u].query[q].question			= universe[origin].query[q].question;
		universe[u].query[q].numberOfOutcomes	= universe[origin].query[q].numberOfOutcomes;
		universe[u].query[q].outcome			= universe[origin].query[q].outcome;
		universe[u].query[q].lastReport			= NO_REPORT;	//resets to NO_REPORT after a fork
		universe[u].query[q].fee				= universe[origin].query[q].fee;		//the REP for this fee was created during forkUniverse(){split()}
		universe[u].query[q].tipToken			= universe[origin].query[q].tipToken;	//if the tipToken is REP, it will be the old worthless REP. REP tips are not split or migrated.
		universe[u].query[q].tip				= universe[origin].query[q].tip;
	}
		
	function resolve(uint _universe, uint query, uint _firstFork) public
	{	//Resolve a Query to a final outcome
		//	_firstFork is left blank unless resolving a fork. Making the client look up this value avoids a new data structure for tracking children.
		//	_firstFork must be the first (lowest ID) child of _universe, unless in forkState 7, where it is instead the first sibling. The first sibling/child is outcome 0.
		require(universe[_universe].repAddress != address(0),"Error: The universe you provided does not exist");
		//all txs are forwarded to the heir. Heir is self until fork, afterwards txs are forwarded to winners of the forking games.
		uint u = universe[_universe].heir;
		require(query < universe[u].nextQuery, 				"Error: The query you provided does not exist");		
		//if the query has no createTime, it means there was a fork and this query still needs to be imported from parent.
		if (universe[u].query[query].createTime == 0)	importQuery(u, query); 
		//Set shorter variables for readability:
		uint thisChild; 	
		uint ancestor;			
		uint currentTime			= block.timestamp;
		uint oneDayAgo	 			= currentTime - ONEDAY;
		uint threeDaysAgo			= currentTime - 3 * ONEDAY;
		uint forkState 				= universe[u].forkState;
		uint forkQuery 				= universe[u].forkQuery;
		uint favoriteChild			= universe[u].favoriteChild;
		uint totalFeeHoldings		= universe[u].totalFeeHoldings;
		uint createTime				= universe[u].query[query].createTime;
		uint outcome				= universe[u].query[query].outcome;
		uint numberOfOutcomes		= universe[u].query[query].numberOfOutcomes;
		uint invalid				= numberOfOutcomes;	//the invalid outcome is the one after the last outcome. The first outcome is outcome 0.
		uint lastReport				= universe[u].query[query].lastReport;
		uint timeOfLastReport		= universe[u].query[query].timeOfLastReport;
		uint nextStake				= universe[u].query[query].nextStake;
		Stake[] storage stake 		= universe[u].query[query].stake;	//turn stake[] into an alias for universe[u].query[query].stake[] ;
		
		require(outcome==UNRESOLVED, 	"Error: This query is already resolved");
		//if this query was created less than three days ago it requires a report before resolving. If longer than 3 days it will resolve invalid.
		if (threeDaysAgo<createTime) require(lastReport!=NO_REPORT, "Error: This query must recieve a report before resolving");
		require(forkState!=1, 			"Error: Queries can not be resolved during a fork");
		require(forkState!=2, 			"Error: Queries can not be resolved during a fork");
		require(forkState!=3, 			"Error: Queries can not be resolved during a fork");
		require(forkState!=4, 			"Error: Queries can not be resolved during a fork");
		require(forkState!=6, 			"Bug: This transaction should have been automatically forwarded to heir");
		if (forkState==5) //if in the final stage of the forking game
		{
			//require that this function was called by advanceForkState() as proven by the fact that auction 6 was initialized with NOT_FOUND on the best bid.
			require(universe[u].auction[6].bestBid==NOT_FOUND,
														"Error: Resolve() can not be called directly to resolve the fork, call advanceForkState() instead");
		}
		else//the forkState equals 0 or 7 due to prior require and if statements.
		{
			require(oneDayAgo>timeOfLastReport, 		"Error: You must wait until the 1 day appeal period ends to resolve this Query");
		}		
		if (forkState==7)	//If this is a new universe only the query that created it can be resolved.
		{					//	resolving it will trigger the final fork updates and set the forkState to 0, this requirement only serves to make that happen.
			require(query==forkQuery,					"Error: Only the Query that created this universe can be resolved");
			require(universe[u].parent == universe[_firstFork  ].parent,
														"Error: The first fork you provided must be a sibling of the universe you provided");
			require(universe[u].parent != universe[_firstFork-1].parent,
														"Error: The first fork you provide must be the first child");						
		}

		/*  at this point the universe exists, the query exists, they have waited long enough to resolve,
			and either the universe is not forking or they are requesting to resolve the fork query while specifying the correct firstFork
			additionally, if the universe is not forking and there are no reports, the query is at least 3 days old.
			this constrains to four scenarios 1) normal resolution, 2) invalid due to no reports, 3) fork resolution on parent 4) fork resolution on child */

		//Resolve a Query Normally
		if (forkState==0)
		{	//If not forking, the final outcome is the most recent report unless there are no reports in which case it is invalid.
			if (lastReport==NO_REPORT)
			{	//resolve as invalid
				outcome 		= invalid;
				//Set the resolver as the reporter so they can be paid.
				stake.push();	//create storage slot for a stake
				stake[0].owner	= msg.sender;
				stake[0].claim	= invalid;
				stake[0].time	= currentTime;
				nextStake		= 1;
				//lastReport is left unchanged so it can be used as an indicator that this query had no reporters.
			}
			else outcome = lastReport; //normal resolution; final outcome is the last report
		}
		//Resolve a universe ready to end the forking game.
		if (forkState==5)
		{
			outcome	= favoriteChild;	// note that heir is set later when the favorite child resolves this fork query within their universe.
		}
		//Resolve a forming universe
		if (forkState==7)	
		{	//children resolve as if their own outcome is correct. 
			outcome = u-_firstFork;	//this child universe id minus the id of the first child is the outcome number
			//Additionally, if this universe is the favorite of its parent, it updates the parents heir to itself.
			//	we then check ancestors of the parent to see if they should also set their heir to this forming universe.
			//	this loop continues checking ancestors, updating their heir if their favoriteChild is the previously checked parent. 
			//	the loop ends when arriving at a child that is not the favorite of its parent.
			thisChild 	= u;					//the first child to check is this forming universe
			ancestor	= universe[u].parent;	//the first ancestor to check is the parent of this forming universe
			while (universe[ancestor].favoriteChild==thisChild)
			{	//for as long as the child is the favorite of the parent
				//	set the heir of the currently examined ancestor to this forming universe.
				universe[ancestor].heir = u;	//causes all transactions addressed to this ancestor to start being forwarded to universe u.
				//update variables in order to check one generation earlier
				ancestor 	= universe[ancestor ].parent;
				thisChild	= universe[thisChild].parent;
			}			
		}
		//ecalation game payoffs happen unless this universe is the parent of a fork (state 5), because after a fork, escalation game payoffs are only done within the children.
		if (forkState!=5)	escalationGamePayoffs(u, query, outcome);
		if (forkState==7)	forkState = 0;	//if resolving a child universe change from forkState 7:forming to 0:normal
		//Save variables
		universe[u].forkState 				= forkState;
		universe[u].favoriteChild			= favoriteChild;
		universe[u].totalFeeHoldings		= totalFeeHoldings;
		universe[u].query[query].outcome	= outcome;
		universe[u].query[query].nextStake	= nextStake;	//this line could be removed if we are sure it will never be referenced again; it only changes during a NO_REPORT resolution.
	}

	function escalationGamePayoffs(uint u, uint query, uint outcome) private
	{	//Used only by resolve() to implement escalation game payoffs
		//set shorter variable names
		uint i;
		uint totalCorrect;
		uint reporterPay;
		uint winnings;				// scaled to 10^18, 1.2 TOKENS = winning reporters get back 1.2 times the stake they put in.
		uint portionCorrect;		// scaled to 10^18, 0.5 TOKENS = 50% of totalStake was staked on the correct outcome.
		uint firstCorrect			= NOT_FOUND; //starts at 10^18 to simplify the for loop that searches for the first correct report
		uint current3day 			= _current3day();
		uint currentTime			= block.timestamp;
		uint totalProfit			= universe[u].totalProfit;
		uint fee					= universe[u].query[query].fee;
		uint nextStake				= universe[u].query[query].nextStake;
		uint totalStake				= universe[u].query[query].totalStake;
		uint lastReport				= universe[u].query[query].lastReport;
		uint createTime				= universe[u].query[query].createTime;
		Stake[] memory stake		= universe[u].query[query].stake;	//import all staking data to stake[]
		ERC20mb rep					= ERC20mb(universe[u].repAddress); 	//import REP's functions
		IERC20 tipToken				= IERC20(universe[u].query[query].tipToken);//import the tip token's functions
		//Add up the total amount staked on the correct answer and save the first correct stake.
		//	this loop is unbounded but the required stake is fee*2^nextStake < forkBond, so 20 loops starts to become implausible
		//	a first correct will always be found because the "if (forkState==0)" earlier rules out normal market with no report by setting stake[0]
		//	,and because its impossible to get to a fork without staking on an outcome.
		for (i=0; i<nextStake ; i++)
		{
			if (stake[i].claim==outcome && firstCorrect==NOT_FOUND)	firstCorrect = i;
			if (stake[i].claim==outcome) 							totalCorrect+= stake[i].amount;
		}
		//Calculate reporter pay. If reported the reporter is paid 0% at create time, and 100% of the query fee 3 days past create time
		if (lastReport!=NO_REPORT) 	reporterPay = (fee * (stake[firstCorrect].time - createTime)) / THREEDAYS;
		else					//If no reports, set the pay to 0% of the fee 3 days past create time, and 100% of the fee 6 days past create time
									reporterPay = (fee * (currentTime - (createTime + THREEDAYS))) / THREEDAYS; 
		if (reporterPay>fee) reporterPay=fee;	// the max pay is the entire query fee
		//pay the first correct reporter the reporter pay
		rep.transfer(stake[firstCorrect].owner, reporterPay);
		//pay the first correct reporter the tip
		tipToken.transfer	(stake[firstCorrect].owner, universe[u].query[query].tip);
		if (lastReport==NO_REPORT) 	portionCorrect = TOKENS;	//if no stakes, the portion correct is 100%.
		else 						portionCorrect = (totalCorrect * TOKENS) / totalStake;	//scaled to 10^18 to allow decimals, wont div0 b/c lastReport!=NO_REPORT => (>0 totalStake)
		//calculate the winnings for the escalation game; the amount winning stakes are multiplied by scaled to 10^18
		//	  return bond +     80%     of the losers money
		//			  1   +    (4/5)     * (( 1 / p ) - 1) 
		winnings = TOKENS + (4*TOKENS/5) * ((TOKENS/portionCorrect) - 1); 
		//burn 20% of losers' stakes as profit to add a cost to delaying resolution.
		rep.burn((totalStake - totalCorrect) / 5); 
		//Transfer stakes from incorrect reporters to correct reporters
		for (i=0; i<nextStake ; i++)	// for every stake
		{
			if (stake[i].claim==outcome)	// if they were correct
			{	// multiply their stake by the winnings and remove the 10^18 scaling.
				stake[i].amount = (stake[i].amount * winnings) / TOKENS; 	
			}
			else							// if they were wrong
			{	//they lose their stake
				stake[i].amount = 0;
			}
		}
		//burn remaining rep as profit
		rep.burn(fee - reporterPay);	
		//Update the universe's financial accounting with the 20% burn and the normal burn.
		totalProfit 								+= (totalStake - totalCorrect) / 5; 
		universe[u].threeDayProfit[current3day] 	+= (totalStake - totalCorrect) / 5;
		totalProfit 								+= fee - reporterPay;
		universe[u].threeDayProfit[current3day] 	+= fee - reporterPay;
		universe[u].totalFeeHoldings 				-= fee;
		universe[u].totalProfit						= totalProfit;
		universe[u].query[query].stake				= stake;
	}

	function withdrawStake(uint _universe, uint query, uint stake) public
	{	//Withdraw REP staked on a resolved Query or any non-forkQuery during forkState 2: initial migration
		require(universe[_universe].repAddress != address(0),	"Error: The universe you provided does not exist");
		//all txs are forwarded to the heir. Heir is self until fork, afterwards txs are forwarded to winners of the forking games.
		uint u = universe[_universe].heir;
		require(query < universe[u].nextQuery, 					"Error: The query you provided does not exist");		
		//skipping importQuery() because a stake withdrawer should never need to import query
		//	the stakes will be obsolete REP unless it is the fork query, and the fork query is copied to each universe during forkUniverse()
		//skipping verifying that this is a valid stake. They will get rejected when the owner is found to be address(0)
		//Shorten variables, this time including query and stake because within the context of this function writing them fully does not improve readability:
		uint q 			= query;
		uint s 			= stake;
		uint forkState 	= universe[u].forkState;
		uint outcome	= universe[u].query[q].outcome;
		uint totalStake	= universe[u].query[q].totalStake;
		uint amount		= universe[u].query[q].stake[s].amount;
		address owner	= universe[u].query[q].stake[s].owner;
		ERC20mb rep 	= ERC20mb(universe[u].repAddress);	//import this universes REP token as rep
		
		require(owner == msg.sender, 					"Error: You do not own that stake");	//require they own the stake
		if (forkState==0 || forkState==7)	//if normal operation or a forming universe, require the query is resolved.
			require(outcome!=UNRESOLVED, 				"Error: You must wait for this Query to resolve before withdrawing your stake");
		
		rep.transfer(msg.sender, amount); 	//send the stake to the message sender
		totalStake -= amount;				//update financial accounting
		amount 		= 0;					//update financial accounting
		//Save variables:
		universe[u].query[q].totalStake		 = totalStake;
		universe[u].query[q].stake[s].amount = amount;
	}

	function advanceForkState(uint _universe, uint _firstFork) public
	{	//Called to finalize initial migration and auctions. Used to enter forkState 3, 4, 5, 6.
		require(universe[_universe].repAddress != address(0),	"Error: The universe you provided does not exist");
		//all txs are forwarded to the heir. Heir is self until fork, afterwards txs are forwarded to winners of the forking games.
		uint u = universe[_universe].heir;
		//Set shorter variables for readability
		uint currentTime				= block.timestamp;
		uint forkQuery					= universe[u].forkQuery;
		uint forkState					= universe[u].forkState;
		uint numberOfOutcomes			= universe[u].query[forkQuery].numberOfOutcomes;
		uint forkStartTime 				= universe[u].query[forkQuery].timeOfLastReport;
		uint state2endTime				= forkStartTime + 14 * ONEDAY;		//forkState 2 and migrate()  end 14 days after the fork starts
		uint state3endTime				= forkStartTime + 21 * ONEDAY;		//forkState 3 and auction[3] end 21 days after the fork starts
		uint state4endTime				= forkStartTime + 26 * ONEDAY;		//forkState 4 and auction[4] end 26 days after the fork starts
		uint state5endTime				= forkStartTime + 28 * ONEDAY;		//forkState 5 and auction[5] end 28 days after the fork starts
		uint bestBid					= universe[u].auction[forkState].bestBid;
		uint mintAmount					= universe[u].auction[forkState].mintAmount;
		uint totalRepInBids				= universe[u].auction[forkState].totalRepInBids;
		Bid[] storage bid 				= universe[u].auction[forkState].bid; //turn bid[] into an alias (changes will impact state)
		address repAddress				= universe[u].repAddress;		
		ERC20mb rep 					= ERC20mb(repAddress);				//import this universes REP token as rep.
		//define repFork[] as an array of ERC20 contracts with a size equal to the number of outcomes.
		ERC20mb[] memory repFork 				= new ERC20mb[](numberOfOutcomes);
		//define an array to track the amount migrated to each outcome within the current auction
		uint[] memory migrationToOutcome 		= new uint[](numberOfOutcomes);	
		//define an array to track the total amount migrated to an outcome. e.g. totalMigrationToOutcome[1] is the total REP migrated to outcome 1 of the forkQuery
		uint[] memory totalMigrationToOutcome	= new uint[](numberOfOutcomes);	
		uint repSold;
		uint thisBid;
		uint thisFork;
		uint thisState;
		uint supplyShortage;
		uint supplyOfThisFork;
		uint thisOutcome;
		uint favoriteChild;			
		uint greatestMigration;
		
		require(forkState != 0,								"Error: This universe must be forking to advance the fork state");
		require(forkState != 1,								"Error: This universe is awaiting children. First call forkUniverse() to create them");
		if (forkState==2)require(currentTime>state2endTime,	"Error: The initial migration has not ended yet");
		if (forkState==3)require(currentTime>state3endTime,	"Error: The first auction has not ended yet");
		if (forkState==4)require(currentTime>state4endTime,	"Error: The second auction has not ended yet");
		if (forkState==5)require(currentTime>state5endTime,	"Error: The third auction has not ended yet");
		require(forkState != 6,								"Bug  : This universe has completed forking and this transaction should have been forwarded to its heir");
		require(forkState != 7,								"Error: This universe is still forming. Its fork state will change to 0 once the parent universe resolves its fork query");
		
		//Total the migration to each outcome so we can find the supply shortage and identify the favorite child.

		//First, lookup the initial migration to each fork
		for (thisFork=_firstFork; thisFork<_firstFork+numberOfOutcomes; thisFork++)
		{	//Starting with _firstFork which represents outcome 0,
			//	go through all forks where the last fork checked is the invalid outcome&fork which has an ID of _firstFork + numberOfOutcomes - 1,
			//	and add the supply of that fork to the total migration to the respective outcome
			//  and import the ERC20 functions of this fork of REP. For example repFork[numberOfOutcomes-1].totalSupply() is the supply of the 'invalid' fork.
			thisOutcome								= thisFork-_firstFork;					//because the first fork is outcome 0 and they are created sequentially
			repFork[thisOutcome]					= ERC20mb(universe[thisFork].repAddress);//import the functions of this fork's rep token  
			supplyOfThisFork 						= repFork[thisOutcome].totalSupply();
			totalMigrationToOutcome[thisOutcome]	= supplyOfThisFork;
		}
		//Second, add the migration from prior finalized auctions.
		for (thisState=3; thisState<forkState; thisState++)
		{	//for each finalized auction
			for (thisOutcome=0; thisOutcome<numberOfOutcomes; thisOutcome++)
			{	//add the migration for each outcome to the total migration for that outcome
				totalMigrationToOutcome[thisOutcome] += universe[u].auction[thisState].migrationToOutcome[thisOutcome];
			}	
		}
		//Third, add the migration from the current auction.
		if(forkState>2)
		{
			if (mintAmount>totalRepInBids) mintAmount=totalRepInBids; //if this auction did not fill, reduce the mintAmount
			thisBid = bestBid;	//starting with the best bid
			while (repSold < mintAmount)
			{	//Add the migration of each winning bid
				thisOutcome 							= bid[thisBid].migrateTo - _firstFork;	//the outcome is the universe the bid migrates to minus the id of the first child
				migrationToOutcome[thisOutcome]		   += bid[thisBid].repAmount;
				totalMigrationToOutcome[thisOutcome]   += bid[thisBid].repAmount;
				repSold 							   += bid[thisBid].repAmount;
				thisBid 								= bid[thisBid].adjacentWorseBid;
			}
			if (repSold > mintAmount)
			{	//Only count the part of the worst winning bid that fits in the auction. repSold is left inaccurate.
				migrationToOutcome[thisOutcome] 	   -= repSold - mintAmount;
				totalMigrationToOutcome[thisOutcome]   -= repSold - mintAmount;
			}
		}
		//Next, find the child with the most total migration and the resulting supply shortage.
		for (thisOutcome=0 ; thisOutcome<numberOfOutcomes; thisOutcome++)
		{	//search all outcomes
			if (totalMigrationToOutcome[thisOutcome] > greatestMigration)
			{	//for the outcome with the greatest migration to set it as the favorite child
				greatestMigration = totalMigrationToOutcome[thisOutcome];
				favoriteChild = _firstFork + thisOutcome;
			}
		}
		supplyShortage = rep.totalSupply() - greatestMigration;

		// Save all variables
		universe[u].favoriteChild							= favoriteChild;
		universe[u].auction[forkState].migrationToOutcome	= migrationToOutcome;
		universe[u].auction[forkState].mintAmount			= mintAmount;	
		universe[u].auction.push();							//create storage for a new auction
		universe[u].auction[forkState+1].mintAmount			= supplyShortage;
		universe[u].auction[forkState+1].bestBid			= NOT_FOUND;
		universe[u].auction[forkState+1].worstBid			= NOT_FOUND;
		if (forkState==5) resolve(u,forkQuery,_firstFork);	//resolve() is placed here because the auction[6].bestBid must be set to prove to resolve() that auction[5] was finalized.
		universe[u].forkState								= forkState+1;
	}

	function createBid(uint repAmount, uint adjacentBetterBid, uint destination) payable public
	{	//Place a bid to buy an amount of minted REP payable with ETH as well as declaring where in the order book the bid should be inserted and a destination universe to migrate to.
		require(universe[destination].repAddress != address(0),	"Error: The universe you provided does not exist");
		//Shorten variables:
		uint parent				= universe[destination].parent;
		uint thisAuction		= universe[parent].forkState; //the auction number is the same as the fork state the auction happens during.
		uint mintAmount			= universe[parent].auction[thisAuction].mintAmount;
		uint thisBid			= universe[parent].auction[thisAuction].nextBid;//this bid will be saved in the next available bid slot which is auction[thisAuction].nextBid								
		uint bestBid			= universe[parent].auction[thisAuction].bestBid;
		uint worstBid			= universe[parent].auction[thisAuction].worstBid;
		Bid[] storage bid 		= universe[parent].auction[thisAuction].bid;	//turn bid[] into an alias for this longer variable name. (changes will impact state)
		uint price;				//Scaled to 10*18 (TOKENS).
		uint betterPrice;		//Scaled to 10*18 (TOKENS).
		uint worsePrice;		//Scaled to 10*18 (TOKENS).
		uint adjacentWorseBid;

		checkIfBiddingAllowed(parent);	//Runs the require statements that make sure bidding is allowed at this time. Spun off into separate function due to stack depth limit.

		//Require the bid is for a valid amount of REP and ETH
		require(msg.value>0,									"Error: You must send ETH with your transaction to make a bid");
		require(repAmount<=mintAmount,							"Error: The amount you bid for is greater than the amount being sold in this auction");
		require(repAmount> mintAmount/10000,					"Error: The minimum amount of REP you can bid for is 0.01% of the auction");
		
		price = (msg.value * TOKENS) / repAmount;	//the ETH paid with this transaction divided by amount of REP demanded is the price. Scaled to 10*18 (TOKENS).
		
		//Make sure the bidder declared the correct location to be inserted in the order book and then accept it.		
		if (bestBid==NOT_FOUND)
		{	//if first bid, accept it.
			adjacentBetterBid 	= NOT_FOUND;
			adjacentWorseBid  	= NOT_FOUND;		
			worstBid			= thisBid;
			bestBid				= thisBid;
		}
		else if(adjacentBetterBid==NOT_FOUND)
		{	//if claiming to be the best bid
			worsePrice			= bid[bestBid].ethAmount * TOKENS / bid[bestBid].repAmount;
			require(price>worsePrice,			"Error: You claimed a better bid than yours was not found, but the best existing bid is offering a higher price than you");
			adjacentWorseBid	= bestBid;
			bestBid				= thisBid;
		}
		else if(adjacentBetterBid==worstBid)
		{	//if claiming to be the worst bid
			betterPrice			= bid[worstBid].ethAmount * TOKENS / bid[worstBid].repAmount;
			require(price<worsePrice,			"Error: You claimed the worst bid is better than yours, but the worst existing bid is offering a lower price than you");
			adjacentWorseBid	= NOT_FOUND;
			worstBid			= thisBid;
		}
		else
		{	//if the bidder is attempting to insert between two existing bids
			require(adjacentBetterBid<thisBid,	"Error: The adjacent better bid you provided is not a valid bid ID");
			betterPrice		= bid[adjacentBetterBid].ethAmount * TOKENS / bid[adjacentBetterBid].repAmount;	//Scaled to 10*18 (TOKENS).
			adjacentWorseBid= bid[adjacentBetterBid].adjacentWorseBid;
			worsePrice		= bid[adjacentWorseBid].ethAmount * TOKENS / bid[adjacentWorseBid].repAmount;	//Scaled to 10*18 (TOKENS).
			require(price<betterPrice,			"Error: The adjacent better bid you provided is not a better bid");
			require(price>worsePrice,			"Error: The adjacent better bid you provided is not an adjacent bid");
		}
		//Save this bid
		bid.push();								//create a storage slot for the new bid
		bid[thisBid].adjacentBetterBid							= adjacentBetterBid;
		bid[thisBid].adjacentWorseBid							= adjacentWorseBid;
		bid[thisBid].owner										= msg.sender;
		bid[thisBid].migrateTo									= destination;
		bid[thisBid].repAmount									= repAmount;
		bid[thisBid].ethAmount									= msg.value;
		//Update adjacent bids to refer to this one (doubly linked list)
		bid[adjacentBetterBid].adjacentWorseBid					= thisBid;
		bid[adjacentWorseBid].adjacentBetterBid					= thisBid;
		//Update the auction
		universe[parent].auction[thisAuction].nextBid			+= 1;				
		universe[parent].auction[thisAuction].totalRepInBids	+= repAmount;
		universe[parent].auction[thisAuction].bestBid			= bestBid;
		universe[parent].auction[thisAuction].worstBid			= worstBid;				
	}

	function checkIfBiddingAllowed(uint u) private view
	{	//Checks if bidding is allowed currently. Only used by createBid()									
		uint currentTime		= block.timestamp;
		uint forkState			= universe[u].forkState;
		uint forkQuery			= universe[u].forkQuery;
		uint forkStartTime 		= universe[u].query[forkQuery].timeOfLastReport;
		uint state3endTime		= forkStartTime + 21 * ONEDAY;					//forkState 3 and auction[3] end 21 days after the fork starts
		uint state4endTime		= forkStartTime + 26 * ONEDAY;					//forkState 4 and auction[4] end 26 days after the fork starts
		uint state5endTime		= forkStartTime + 28 * ONEDAY;					//forkState 5 and auction[5] end 28 days after the fork starts		
		//Require the universe is in the correct forking state for bidding.
		require(forkState!=0, 									"Error: There is no auction. Auctions happen during a fork after initial migration");
		require(forkState!=1, 									"Bug: It should not be possible for this destination universe to pass the earlier require(exists) while it's parent is in forkState 1: awaiting children");
		require(forkState!=2, 									"Error: There is no auction. Wait until the initial migration period ends then call advanceForkState()");
		if (forkState==3) require(currentTime<state3endTime,	"Error: It is time for the current auction to end. Call advanceForkState() instead");
		if (forkState==4) require(currentTime<state4endTime,	"Error: It is time for the current auction to end. Call advanceForkState() instead");
		if (forkState==5) require(currentTime<state5endTime,	"Error: It is time for the current auction to end. Call advanceForkState() instead");
		require(forkState<6,									"Error: The auctions have ended");	
	}

	function collect(uint _universe) public
	{	//Transfer REP won in the auction to your wallet
		//uint totalSurplus;			// The total quantity of ETH that would be returned to winning bidders if the auction settled using the lower VCG price
		//uint totalRaised;			// The total quantity of ETH that would be raised if the auction settled using the VCG price.
		//uint totalRaisedSellingHalf;	// The total quantity of ETH that would be raised if the auction settled using the VCG price and half as much supply was sold.			
		//uint totalSurplusSellingHalf;// The total quantity of ETH that would be returned to winning bidders if the auction settled using the lower VCG price and half as much supply was sold.
	}

	function createQueryTokenizer(uint _universe) private returns (address tokenizerAddress)
	{	//Deploy a contract to manage query tokens for a _universe
		
	}

	function createREP(uint _universe) public returns (address repAddress)
	{	//Deploy a REP token for a _universe  ###set to public for testing, change back to private
		require(_universe<universe.length,	"Error: The universe you provided does not exist");
		//require(universe[_universe].repAddress == address(0),	"Error: The universe you provided already has a REP address");   reconsider requires after testing
		uint ticker;
		uint thisUniverse				= _universe;
		uint parent 					= universe[_universe].parent;
		uint forkQuery					= universe[parent].forkQuery;
		string memory tokenName 		= "Reputation";
		string memory tickerNumbers;
		//To determine the ticker, we create a string of outcome numbers required to go from universe 0 to the user provided universe
		while (thisUniverse!=0)	//do the below steps until arriving at universe 0
		{	//first convert to a string and save the outcome number associated with this universe by appending to the start of tickerNumbers
			//	the outcome id associated with a child universe is always the same as the difference between the parent and child universe ids minus 1.
			tickerNumbers = string.concat(strings.toString(thisUniverse - universe[thisUniverse].parent - 1), tickerNumbers);
			//then add a period between numbers. checking if the loop is about to end is how we know we are between numbers
			if (universe[thisUniverse].parent != 0)	tickerNumbers = string.concat(".",tickerNumbers);
			thisUniverse = universe[thisUniverse].parent;						//then switch to checking the parent of this this universe
		}	
		ticker 		= string.concat("REP", tickerNumbers); 	//For example, if getting to this universe required 3 forks, outcome 1, 4, then 0, then the ticker would be REP1.4.0
										//perhaps instead periods should only be added before two digit outcome numbers, REP140 seems ok.
		ERC20mb rep = new ERC20mb(address(this),tokenName,ticker);		//deploy the REP token with this contract address having the power to mint
		address repAddress = address(rep);	//import this new REP token so functions like mint can be called.
		if (_universe == 0) 	// ### this if statement is added for testing. delete.
		{
			rep.mint(msg.sender, 11000000 * TOKENS);
			universe[0].repAddress = repAddress;
		}
	}



/*
		TODO
Outcome id is equal to child id minus parent id MINUS ONE. However, outcome number which counts starting at 1 is simply child id minus parent id. Check for mistakes related to this.
Add memory to variables to reduce gas
Consider getting rid of nextQuery variable and instead using query.length
Consider checking if universes exist using universe.length instead of erc20 exists.
Find a way to skip auctions if >2/3 of original supply has migrated to a fork. Restoring supply at this point is only harmful.
Double check that reporter pay got subtracted out of the bonds that will later be transferred when settling the escalation game.
Consider if advanceForkState() can be made to cover more forkstates, by forwarding to existing functions
Add the contract that enables premature queries.
Some for loops can be switched to while loops which is more fitting.
Switch from burning by transferring to address 0 to rep.burn(amount) now that ERC20mb.sol is included. This will ensure totalSupply() is correct.
upgrade all interactions with the arbitrary tip token to safeTransfer()
add error for not doing approval tx. require(token.allowance(msg.sender, address(this)) >= amount, "Error: ###");
universes are appended onto the end when creating new ones, its possible for two different universes to be in a fork at the same time, check if this causes any issues. 
solve the problem of a fork resulting in empty revenue and profit data for a month... it also results in max reporter pay ; add 28 days to all time and create times?
	will it though? the data is copied over immediately , and in the forming universe queries should be allowed to be created and resolved. seems like revenue and profit is not messed with. 
	what about max reporter pay though and invalid due to no reports. This makes it even more important to enable reporting and resolution in a forming universe. What needs to happen is:
	enable reporting and resolving Queries in a forming universe. The main concern is the updates that happen when it switches to forkState=0. The other concern is what happens if a forming universe tries to fork before its parent resolves its fork?
add claiming and migrating rewards from the supply restoration auction
finish setting flags for the functions
add event logging emit
deploy to testnet
*/

	function _current3day() private view returns (uint current3day)
	{	//Calculate the current 3day; the bucket that new revenue would be logged in
		//	due to the 60 days of fake revenue added when the multiverse is created, index 0 through 19 starts filled
		//	at the start of the protocol, the current3day is 20 for the first THREEDAYS.
		//	uint will always round down, which is desired here because increments happen at the end of a THREEDAYS period.
		current3day = 20 + (block.timestamp - universe[0].query[0].createTime) / THREEDAYS;
	}

	function max(uint a, uint b) private pure returns (uint) 
	{	//Returns the max of a and b
		return a > b ? a : b;
	}
		
}