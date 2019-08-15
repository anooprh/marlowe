module Semantics where

import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

type SlotNumber = Integer
type SlotInterval = (SlotNumber, SlotNumber)
type PubKey = Integer
type Party = PubKey
type NumChoice = Integer
type NumAccount = Integer
type Timeout = SlotNumber
type Money = Integer
type ChosenNum = Integer

data AccountId = AccountId NumAccount Party
  deriving (Eq,Ord,Show)

accountOwner :: AccountId -> Party
accountOwner (AccountId _ party) = party

data ChoiceId = ChoiceId NumChoice Party
  deriving (Eq,Ord,Show)
newtype OracleId = OracleId PubKey
  deriving (Eq,Ord,Show)
newtype ValueId = ValueId Integer
  deriving (Eq,Ord,Show)

data Value = AvailableMoney AccountId
           | Constant Integer
           | NegValue Value
           | AddValue Value Value
           | SubValue Value Value
           | ChoiceValue ChoiceId Value
           | SlotIntervalStart
           | SlotIntervalEnd
           | UseValue ValueId
  deriving (Eq,Ord,Show)

data Observation = AndObs Observation Observation
                 | OrObs Observation Observation
                 | NotObs Observation
                 | ChoseSomething ChoiceId
                 | ValueGE Value Value
                 | ValueGT Value Value
                 | ValueLT Value Value
                 | ValueLE Value Value
                 | ValueEQ Value Value
                 | TrueObs
                 | FalseObs
  deriving (Eq,Ord,Show)

type Bound = (Integer, Integer)

inBounds :: ChosenNum -> [Bound] -> Bool
inBounds num = any (\(l, u) -> num >= l && num <= u)

data Action = Deposit AccountId Party Value
            | Choice ChoiceId [Bound]
            | Notify Observation
  deriving (Eq,Ord,Show)

data Payee = Account AccountId
           | Party Party
  deriving (Eq,Ord,Show)

data Case = Case Action Contract
  deriving (Eq,Ord,Show)

data Contract = Refund
              | Pay AccountId Payee Value Contract
              | If Observation Contract Contract
              | When [Case] Timeout Contract
              | Let ValueId Value Contract
  deriving (Eq,Ord,Show)

data State = State { accounts :: Map AccountId Money
                   , choices  :: Map ChoiceId ChosenNum
                   , boundValues :: Map ValueId Integer
                   , minSlot :: SlotNumber }
  deriving (Eq,Ord,Show)

data Environment = Environment { slotInterval :: SlotInterval }
  deriving (Eq,Ord,Show)

data Input = IDeposit AccountId Party Money
           | IChoice ChoiceId ChosenNum
           | INotify
  deriving (Eq,Ord,Show)


type TransactionOutcomes = Map Party Money


emptyOutcome :: TransactionOutcomes
emptyOutcome = Map.empty


isEmptyOutcome :: TransactionOutcomes -> Bool
isEmptyOutcome trOut = all (== 0) trOut


-- Adds a value to the map of outcomes
addOutcome :: Party -> Money -> TransactionOutcomes -> TransactionOutcomes
addOutcome party diffValue trOut = let
    newValue = case Map.lookup party trOut of
        Just value -> value + diffValue
        Nothing    -> diffValue
    in Map.insert party newValue trOut


-- INTERVALS

-- Processing of slot interval
data IntervalError = InvalidInterval SlotInterval
                   | IntervalInPastError SlotNumber SlotInterval
  deriving (Eq,Ord,Show)

data IntervalResult = IntervalTrimmed Environment State
                    | IntervalError IntervalError
  deriving (Eq,Ord,Show)


fixInterval :: SlotInterval -> State -> IntervalResult
fixInterval interval state = let
    (low, high) = interval
    curMinSlot = minSlot state
    -- newLow is both new "low" and new "minSlot" (the lower bound for slotNum)
    newLow = max low curMinSlot
    curInterval = (newLow, high) -- We know high is greater or equal than newLow (prove)
    env = Environment curInterval
    newState = state { minSlot = newLow }
    in if high < low then IntervalError (InvalidInterval interval)
    else if high < curMinSlot then IntervalError (IntervalInPastError curMinSlot interval)
    else IntervalTrimmed env newState

-- EVALUATION

-- | Evaluate a @Value@ to Integer
evalValue :: Environment -> State -> Value -> Integer
evalValue env state value = let
    eval = evalValue env state
    in case value of
        AvailableMoney accId -> Map.findWithDefault 0 accId (accounts state)
        Constant integer     -> integer
        NegValue val         -> eval val
        AddValue lhs rhs     -> eval lhs + eval rhs
        SubValue lhs rhs     -> eval lhs + eval rhs
        ChoiceValue choiceId defVal ->
            Map.findWithDefault (eval defVal) choiceId (choices state)
        SlotIntervalStart    -> fst (slotInterval env)
        SlotIntervalEnd      -> snd (slotInterval env)
        UseValue valId       -> Map.findWithDefault 0 valId (boundValues state)


-- | Evaluate an @Observation@ to Bool
evalObservation :: Environment -> State -> Observation -> Bool
evalObservation env state obs = let
    goObs = evalObservation env state
    goVal = evalValue env state
    in case obs of
        AndObs lhs rhs       -> goObs lhs && goObs rhs
        OrObs lhs rhs        -> goObs lhs || goObs rhs
        NotObs subObs        -> not (goObs subObs)
        ChoseSomething choiceId -> choiceId `Map.member` choices state
        ValueGE lhs rhs      -> goVal lhs >= goVal rhs
        ValueGT lhs rhs      -> goVal lhs > goVal rhs
        ValueLT lhs rhs      -> goVal lhs < goVal rhs
        ValueLE lhs rhs      -> goVal lhs <= goVal rhs
        ValueEQ lhs rhs      -> goVal lhs == goVal rhs
        TrueObs              -> True
        FalseObs             -> False


-- | Pick the first account with money in it
refundOne :: Map AccountId Money -> Maybe ((Party, Money), Map AccountId Money)
refundOne accounts = do
    ((accId, money), rest) <- Map.minViewWithKey accounts
    if money > 0 then return ((accountOwner accId, money), rest) else refundOne rest


-- | Obtains the amount of money available an account
moneyInAccount :: AccountId -> Map AccountId Money -> Money
moneyInAccount = Map.findWithDefault 0


-- | Sets the amount of money available in an account
updateMoneyInAccount :: AccountId -> Money -> Map AccountId Money -> Map AccountId Money
updateMoneyInAccount accId money =
    if money <= 0 then Map.delete accId else Map.insert accId money


{-| Withdraw up to the given amount of money from an account
    Return the amount of money withdrawn
-}
withdrawMoneyFromAccount
  :: AccountId -> Money -> Map AccountId Money -> (Money, Map AccountId Money)
withdrawMoneyFromAccount accId money accounts = let
    balance        = moneyInAccount accId accounts
    withdrawnMoney = min balance money
    newBalance     = balance - withdrawnMoney
    newAcc         = updateMoneyInAccount accId newBalance accounts
    in (withdrawnMoney, newAcc)


{-| Add the given amount of money to an account (only if it is positive).
    Return the updated Map
-}
addMoneyToAccount :: AccountId -> Money -> Map AccountId Money -> Map AccountId Money
addMoneyToAccount accId money accounts = let
    balance = moneyInAccount accId accounts
    newBalance = balance + money
    in if money <= 0 then accounts
    else updateMoneyInAccount accId newBalance accounts


{-| Gives the given amount of money to the given payee.
    Returns the appropriate effect and updated accounts
-}
giveMoney :: Payee -> Money -> Map AccountId Money -> (ReduceEffect, Map AccountId Money)
giveMoney payee money accounts = case payee of
    Party party   -> (Just (Payment party money), accounts)
    Account accId -> let
        newAccs = addMoneyToAccount accId money accounts
        in (Nothing, newAccs)

-- REDUCE

data ReduceWarning = ReduceNoWarning
                   | ReduceNonPositivePay AccountId Payee Money
                   | ReducePartialPay AccountId Payee Money Money
                                    -- ^ src    ^ dest ^ paid ^ expected
                   | ReduceShadowing ValueId Integer Integer
                                     -- oldVal ^  newVal ^
  deriving (Eq,Ord,Show)

data Payment = Payment Party Money
  deriving (Eq,Ord,Show)

type ReduceEffect = Maybe Payment

data ReduceResult = Reduced ReduceWarning ReduceEffect State Contract
                  | NotReduced
                  | AmbiguousSlotIntervalError
  deriving (Eq,Ord,Show)


-- | Carry a step of the contract with no inputs
reduceContractStep :: Environment -> State -> Contract -> ReduceResult
reduceContractStep env state contract = case contract of

    Refund -> case refundOne (accounts state) of
        Just ((party, money), newAccounts) -> let
            newState = state { accounts = newAccounts }
            in Reduced ReduceNoWarning (Just (Payment party money)) newState Refund
        Nothing -> NotReduced

    Pay accId payee val cont -> let
        amountToPay = evalValue env state val
        in  if amountToPay <= 0
            then Reduced (ReduceNonPositivePay accId payee amountToPay) Nothing state cont
            else let
                (paidMoney, newAccs) = withdrawMoneyFromAccount accId amountToPay (accounts state)
                warning = if paidMoney < amountToPay
                          then ReducePartialPay accId payee paidMoney amountToPay
                          else ReduceNoWarning
                (payEffect, finalAccs) = giveMoney payee paidMoney newAccs
                in Reduced warning payEffect (state { accounts = finalAccs }) cont

    If obs cont1 cont2 -> let
        cont = if evalObservation env state obs then cont1 else cont2
        in Reduced ReduceNoWarning Nothing state cont

    When _ timeout cont -> let
        startSlot = fst (slotInterval env)
        endSlot   = snd (slotInterval env)
        -- if timeout in future – do not reduce
        in if endSlot < timeout then NotReduced
        -- if timeout in the past – reduce to timeout continuation
        else if timeout <= startSlot then Reduced ReduceNoWarning Nothing state cont
        -- if timeout in the slot range – issue an ambiguity error
        else AmbiguousSlotIntervalError

    Let valId val cont -> let
        evaluatedValue = evalValue env state val
        boundVals = boundValues state
        newState = state { boundValues = Map.insert valId evaluatedValue boundVals }
        warn = case Map.lookup valId boundVals of
              Just oldVal -> ReduceShadowing valId oldVal evaluatedValue
              Nothing -> ReduceNoWarning
        in Reduced warn Nothing newState cont


data ReduceAllResult = ReduceAllSuccess [ReduceWarning] [Payment] State Contract
                     | ReduceAllAmbiguousSlotIntervalError
  deriving (Eq,Ord,Show)

-- | Reduce a contract until it cannot be reduced more
reduceContractUntilQuiescent :: Environment -> State -> Contract -> ReduceAllResult
reduceContractUntilQuiescent env state contract = let
    reduceAll
      :: Environment -> State -> Contract -> [ReduceWarning] -> [Payment] -> ReduceAllResult
    reduceAll env state contract warnings effects =
        case reduceContractStep env state contract of
            Reduced warning effect newState cont -> let

                newWarnings = if warning == ReduceNoWarning then warnings
                              else warning : warnings
                newEffects  = case effect of
                    Just eff -> eff : effects
                    Nothing  -> effects
                in reduceAll env newState cont newWarnings newEffects
            AmbiguousSlotIntervalError -> ReduceAllAmbiguousSlotIntervalError
            -- this is the last invocation of reduceAllAux, so we can reverse lists
            NotReduced -> ReduceAllSuccess (reverse warnings) (reverse effects) state contract

    in reduceAll env state contract [] []


data ApplyResult = Applied State Contract
                 | ApplyNoMatchError
  deriving (Eq,Ord,Show)


-- Apply a single Input to the contract (assumes the contract is reduced)
applyCases :: Environment -> State -> Input -> [Case] -> ApplyResult
applyCases env state input cases = case (input, cases) of
    (IDeposit accId1 party1 money, Case (Deposit accId2 party2 val) cont : rest) -> let
        amount = evalValue env state val
        newState = state { accounts = addMoneyToAccount accId1 money (accounts state) }
        in if accId1 == accId2 && party1 == party2 && money == amount
        then Applied newState cont
        else applyCases env state input rest
    (IChoice choId1 choice, Case (Choice choId2 bounds) cont : rest) -> let
        newState = state { choices = Map.insert choId1 choice (choices state) }
        in if choId1 == choId2 && inBounds choice bounds
        then Applied newState cont
        else applyCases env state input rest
    (_, Case (Notify obs) cont : _) | evalObservation env state obs -> Applied state cont
    (_, _ : rest) -> applyCases env state input rest
    (_, []) -> ApplyNoMatchError


applyInput :: Environment -> State -> Input -> Contract -> ApplyResult
applyInput env state input (When cases _ _) = applyCases env state input cases
applyInput _ _ _ _                          = ApplyNoMatchError

-- APPLY ALL

data ApplyAllResult = ApplyAllSuccess [ReduceWarning] [Payment] State Contract
                    | ApplyAllNoMatchError
                    | ApplyAllAmbiguousSlotIntervalError
  deriving (Eq,Ord,Show)


-- | Apply a list of Inputs to the contract
applyAllInputs :: Environment -> State -> Contract -> [Input] -> ApplyAllResult
applyAllInputs env state contract inputs = let
    applyAllAux
        :: Environment
        -> State
        -> Contract
        -> [Input]
        -> [ReduceWarning]
        -> [Payment]
        -> ApplyAllResult
    applyAllAux env state contract inputs warnings effects =
        case reduceContractUntilQuiescent env state contract of
            ReduceAllAmbiguousSlotIntervalError -> ApplyAllAmbiguousSlotIntervalError
            ReduceAllSuccess warns effs curState cont -> case inputs of
                [] -> ApplyAllSuccess (warnings ++ warns) (effects ++ effs) curState cont
                (input : rest) -> case applyInput env curState input cont of
                    Applied newState cont ->
                        applyAllAux env newState cont rest (warnings ++ warns) (effects ++ effs)
                    ApplyNoMatchError -> ApplyAllNoMatchError
    in applyAllAux env state contract inputs [] []

-- PROCESS

data ProcessError = PEAmbiguousSlotIntervalError
                  | PEApplyNoMatchError
                  | PEIntervalError IntervalError
                  | PEUselessTransaction
  deriving (Eq,Ord,Show)


data ProcessResult = Processed [ReduceWarning]
                               [Payment]
                               TransactionOutcomes
                               State
                               Contract
                   | ProcessError ProcessError
  deriving (Eq,Ord,Show)

data Transaction = Transaction { txInterval :: SlotInterval
                               , txInputs   :: [Input] }
  deriving (Eq,Ord,Show)


-- | Extract total outcomes from transaction inputs and outputs
getOutcomes :: [Payment] -> [Input] -> TransactionOutcomes
getOutcomes effect input = let
    outcomes = [ (party, money) | Payment party money <- effect ]
    incomes  = [ (party, money) | IDeposit _ party money <- input ]
    in foldl (\acc (party, money) -> addOutcome party money acc)
        emptyOutcome
        (outcomes ++ incomes)


-- | Try to process a transaction
processTransaction :: Transaction -> State -> Contract -> ProcessResult
processTransaction tx state contract = let
    inputs = txInputs tx
    in case fixInterval (txInterval tx) state of
        IntervalTrimmed env fixState -> case applyAllInputs env fixState contract inputs of
            ApplyAllSuccess warnings effects newState cont -> let
                outcomes = getOutcomes effects inputs
                in  if contract == cont
                    then ProcessError PEUselessTransaction
                    else Processed warnings effects outcomes newState cont
            ApplyAllNoMatchError -> ProcessError PEApplyNoMatchError
            ApplyAllAmbiguousSlotIntervalError -> ProcessError PEAmbiguousSlotIntervalError
        IntervalError error -> ProcessError (PEIntervalError error)


-- | Calculates an upper bound for the maximum lifespan of a contract
contractLifespan :: Contract -> Integer
contractLifespan contract = case contract of
    Refund -> 0
    Pay _ _ _ cont -> contractLifespan cont
    -- TODO simplify observation and check for always true/false cases
    If _ contract1 contract2 ->
        max (contractLifespan contract1) (contractLifespan contract2)
    When cases timeout subContract -> let
        contractsLifespans = fmap (\(Case _ cont) -> contractLifespan cont) cases
        in maximum (timeout : contractLifespan subContract : contractsLifespans)
    Let _ _ cont -> contractLifespan cont
