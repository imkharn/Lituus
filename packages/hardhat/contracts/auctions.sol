// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;
import {ERC20mb} from "./ERC20mb.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IMultiverse
{	//This list tells this contract which functions from the multiverse contract are available to be called.
    function _forkState(uint u) external view returns (uint);
    function _forkQuery(uint u) external view returns (uint);
    function _numberOfOutcomes(uint u, uint q) external view returns (uint);
    function _timeOfLastReport(uint u, uint q) external view returns (uint);
    function _repAddress(uint u) external view returns (address);
    function setFavoriteChild(uint u, uint favorite) external;
    function setForkState(uint u, uint state) external;
    function resolve(uint _universe, uint query, uint _firstFork) external;
    function _parent(uint u) external view returns (uint);
}


contract Auctions is ReentrancyGuard
{
	using SafeERC20 for IERC20;

	uint immutable TOKENS 					= 10**18;		//used both for token quantities and to scale numbers as to enable decimals
	uint immutable NOT_FOUND				= 10**18;		//used as a null value in for-loops that search
	uint immutable ONEDAY					= 86400;		//seconds
	
	//Setup the auction structure which is 	auction[A].bid[B]
	//										auction[A].rejectedPaymentsSumOfTop[K]
	//										auction[A].rejectedAmountsSumOfTop[K]
	//										auction[A].migrationToOutcome[O]
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

    Auction[] public auction;		//enables multiple auctions in the format auction[A].
	IMultiverse public multiverse;	//enables calling functions on the multiverse contract using multiverse.function(). IMultiverse contains the list of functions.

	constructor(address multiverseAddress) 
	{	//when this contract is created, the creator must inform it of the address of the already deployed multiverse contract.
        multiverse = IMultiverse(multiverseAddress);	//the provided address is saved so multiverse.function() knows which contract address to call.
    }

	function advanceForkState(uint _universe, uint _firstFork) public
	{	//Called to finalize initial migration and auctions. Used to enter forkState 3, 4, 5, 6.
		require(multiverse._repAddress(_universe) != address(0),	"Error: The universe you provided does not exist");
		
		//Set shorter variables for readability
		uint u 							= _universe;						//forking and auction txs are not forwarded to heir
		uint currentTime				= block.timestamp;
		uint forkQuery					= multiverse._forkQuery(u);
		uint forkState					= multiverse._forkState(u);
		uint numberOfOutcomes			= multiverse._numberOfOutcomes(u, forkQuery);
		uint forkStartTime 				= multiverse._timeOfLastReport(u, forkQuery);
		uint state2endTime				= forkStartTime + 14 * ONEDAY;		//forkState 2 and migrate()  end 14 days after the fork starts
		uint state3endTime				= forkStartTime + 21 * ONEDAY;		//forkState 3 and auction[3] end 21 days after the fork starts
		uint state4endTime				= forkStartTime + 26 * ONEDAY;		//forkState 4 and auction[4] end 26 days after the fork starts
		uint state5endTime				= forkStartTime + 28 * ONEDAY;		//forkState 5 and auction[5] end 28 days after the fork starts
		uint bestBid					= auction[forkState].bestBid;
		uint mintAmount					= auction[forkState].mintAmount;
		uint totalRepInBids				= auction[forkState].totalRepInBids;
		Bid[] storage bid 				= auction[forkState].bid; //turn bid[] into an alias (changes will impact state)
		address repAddress				= multiverse._repAddress(u);
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
			repFork[thisOutcome]					= ERC20mb(multiverse._repAddress(thisFork));//import the functions of this fork's rep token  
			supplyOfThisFork 						= repFork[thisOutcome].totalSupply();
			totalMigrationToOutcome[thisOutcome]	= supplyOfThisFork;
		}
		//Second, add the migration from prior finalized auctions.
		for (thisState=3; thisState<forkState; thisState++)
		{	//for each finalized auction
			for (thisOutcome=0; thisOutcome<numberOfOutcomes; thisOutcome++)
			{	//add the migration for each outcome to the total migration for that outcome
				totalMigrationToOutcome[thisOutcome] += auction[thisState].migrationToOutcome[thisOutcome];
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
		multiverse.setFavoriteChild(u, favoriteChild);
		auction[forkState].migrationToOutcome	= migrationToOutcome;
		auction[forkState].mintAmount			= mintAmount;	
		auction.push();							//create storage for a new auction
		auction[forkState+1].mintAmount			= supplyShortage;
		auction[forkState+1].bestBid			= NOT_FOUND;
		auction[forkState+1].worstBid			= NOT_FOUND;
		if (forkState==5) multiverse.resolve(u,forkQuery,_firstFork);	//resolve the fork query on the multiverse while the parent is still in fork state 5, before setForkState(u, forkState+1) moves it to 6.
		multiverse.setForkState(u, forkState+1);
	}

	function createBid(uint repAmount, uint adjacentBetterBid, uint destination) payable public
	{	//Place a bid to buy an amount of minted REP payable with ETH as well as declaring where in the order book the bid should be inserted and a destination universe to migrate to.
		require(multiverse._repAddress(destination) != address(0),	"Error: The universe you provided does not exist");
		//Shorten variables:
		uint parent				= multiverse._parent(destination);
		uint thisAuction		= multiverse._forkState(parent); //the auction number is the same as the fork state the auction happens during.
		uint mintAmount			= auction[thisAuction].mintAmount;
		uint thisBid			= auction[thisAuction].nextBid;//this bid will be saved in the next available bid slot which is auction[thisAuction].nextBid								
		uint bestBid			= auction[thisAuction].bestBid;
		uint worstBid			= auction[thisAuction].worstBid;
		Bid[] storage bid 		= auction[thisAuction].bid;	//turn bid[] into an alias for this longer variable name. (changes will impact state)
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
		auction[thisAuction].nextBid							+= 1;				
		auction[thisAuction].totalRepInBids	    				+= repAmount;
		auction[thisAuction].bestBid							= bestBid;
		auction[thisAuction].worstBid							= worstBid;				
	}

	function checkIfBiddingAllowed(uint u) private view
	{	//Checks if bidding is allowed currently. Only used by createBid()									
		uint currentTime		= block.timestamp;
		uint forkState			= multiverse._forkState(u);
		uint forkQuery			= multiverse._forkQuery(u);
		uint forkStartTime 		= multiverse._timeOfLastReport(u, forkQuery);
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


		
}


