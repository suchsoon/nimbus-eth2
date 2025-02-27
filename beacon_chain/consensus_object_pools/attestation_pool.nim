# beacon_chain
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/algorithm,
  # Status libraries
  metrics,
  chronicles, stew/byteutils,
  # Internal
  ../spec/[
    beaconstate, eth2_merkleization, forks, state_transition_epoch, validator],
  "."/[spec_cache, blockchain_dag, block_quarantine],
  ../fork_choice/fork_choice,
  ../beacon_clock

from std/sequtils import keepItIf, maxIndex

export blockchain_dag, fork_choice

const
  # TODO since deneb, this is looser (whole previous epoch)
  ATTESTATION_LOOKBACK =
    min(24'u64, SLOTS_PER_EPOCH) + MIN_ATTESTATION_INCLUSION_DELAY
    ## The number of slots we'll keep track of in terms of "free" attestations
    ## that potentially could be added to a newly created block

type
  OnPhase0AttestationCallback =
    proc(data: phase0.Attestation) {.gcsafe, raises: [].}
  OnElectraAttestationCallback =
    proc(data: electra.Attestation) {.gcsafe, raises: [].}

  Validation[CVBType] = object
    ## Validations collect a set of signatures for a distict attestation - in
    ## eth2, a single bit is used to keep track of which signatures have been
    ## added to the aggregate meaning that only non-overlapping aggregates may
    ## be further combined.
    aggregation_bits: CVBType
    aggregate_signature: AggregateSignature

  Phase0Validation = Validation[CommitteeValidatorsBits]
  ElectraValidation = Validation[ElectraCommitteeValidatorsBits]

  AttestationEntry[CVBType] = object
    ## Each entry holds the known signatures for a particular, distinct vote
    ## For electra+, the data has been changed to hold the committee index
    data: AttestationData
    committee_len: int
    singles: Table[int, CookedSig] ## \
      ## On the attestation subnets, only attestations with a single vote are
      ## allowed - these can be collected separately to top up aggregates with -
      ## here we collect them by mapping index in committee to a vote
    aggregates: seq[Validation[CVBType]]

  Phase0AttestationEntry = AttestationEntry[CommitteeValidatorsBits]
  ElectraAttestationEntry = AttestationEntry[ElectraCommitteeValidatorsBits]

  AttestationTable[CVBType] = Table[Eth2Digest, AttestationEntry[CVBType]]
    ## Depending on the world view of the various validators, they may have
    ## voted on different states - this map keeps track of each vote keyed by
    ## getAttestationCandidateKey()

  AttestationPool* = object
    ## The attestation pool keeps track of all attestations that potentially
    ## could be added to a block during block production.
    ## These attestations also contribute to the fork choice, which combines
    ## "free" attestations with those found in past blocks - these votes
    ## are tracked separately in the fork choice.

    phase0Candidates: array[ATTESTATION_LOOKBACK.int,
        AttestationTable[CommitteeValidatorsBits]] ## \
      ## We keep one item per slot such that indexing matches slot number
      ## together with startingSlot

    electraCandidates: array[ATTESTATION_LOOKBACK.int,
        AttestationTable[ElectraCommitteeValidatorsBits]] ## \
      ## We keep one item per slot such that indexing matches slot number
      ## together with startingSlot

    startingSlot: Slot ## \
    ## Generally, we keep attestations only until a slot has been finalized -
    ## after that, they may no longer affect fork choice.

    dag*: ChainDAGRef
    quarantine*: ref Quarantine

    forkChoice*: ForkChoice

    nextAttestationEpoch*: seq[tuple[subnet: Epoch, aggregate: Epoch]] ## \
    ## sequence based on validator indices

    onPhase0AttestationAdded: OnPhase0AttestationCallback
    onElectraAttestationAdded: OnElectraAttestationCallback

logScope: topics = "attpool"

declareGauge attestation_pool_block_attestation_packing_time,
  "Time it took to create list of attestations for block"

proc init*(T: type AttestationPool, dag: ChainDAGRef,
           quarantine: ref Quarantine,
           onPhase0Attestation: OnPhase0AttestationCallback = nil,
           onElectraAttestation: OnElectraAttestationCallback = nil): T =
  ## Initialize an AttestationPool from the dag `headState`
  ## The `finalized_root` works around the finalized_checkpoint of the genesis block
  ## holding a zero_root.
  let finalizedEpochRef = dag.getFinalizedEpochRef()

  var forkChoice = ForkChoice.init(
    finalizedEpochRef, dag.finalizedHead.blck)

  # Feed fork choice with unfinalized history - during startup, block pool only
  # keeps track of a single history so we just need to follow it
  doAssert dag.heads.len == 1, "Init only supports a single history"

  var blocks: seq[BlockRef]
  var cur = dag.head

  # When the chain is finalizing, the votes between the head block and the
  # finalized checkpoint should be enough for a stable fork choice - when the
  # chain is not finalizing, we want to seed it with as many votes as possible
  # since the whole history of each branch might be significant. It is however
  # a game of diminishing returns, and we have to weigh it against the time
  # it takes to replay that many blocks during startup and thus miss _new_
  # votes.
  const ForkChoiceHorizon = 256
  while cur != dag.finalizedHead.blck:
    blocks.add cur
    cur = cur.parent

  info "Initializing fork choice", unfinalized_blocks = blocks.len

  var epochRef = finalizedEpochRef
  for i in 0..<blocks.len:
    let
      blckRef = blocks[blocks.len - i - 1]
      status =
        if i < (blocks.len - ForkChoiceHorizon) and (i mod 1024 != 0):
          # Fork choice needs to know about the full block tree back through the
          # finalization point, but doesn't really need to have overly accurate
          # justification and finalization points until we get close to head -
          # nonetheless, we'll make sure to pass a fresh finalization point now
          # and then to make sure the fork choice data structure doesn't grow
          # too big - getting an EpochRef can be expensive.
          forkChoice.backend.process_block(
            blckRef.bid, blckRef.parent.root, epochRef.checkpoints)
        else:
          epochRef = dag.getEpochRef(blckRef, blckRef.slot.epoch, false).expect(
            "Getting an EpochRef should always work for non-finalized blocks")
          let
            blck = dag.getForkedBlock(blckRef.bid).expect(
              "Should be able to load initial fork choice blocks")
            unrealized =
              if blckRef == dag.head:
                withState(dag.headState):
                  when consensusFork >= ConsensusFork.Altair:
                    forkyState.data.compute_unrealized_finality()
                  else:
                    var cache: StateCache
                    forkyState.data.compute_unrealized_finality(cache)
              else:
                default(FinalityCheckpoints)
          withBlck(blck):
            forkChoice.process_block(
              dag, epochRef, blckRef, unrealized, forkyBlck.message,
              blckRef.slot.start_beacon_time)

    doAssert status.isOk(), "Error in preloading the fork choice: " & $status.error

  info "Fork choice initialized",
    justified = shortLog(getStateField(
      dag.headState, current_justified_checkpoint)),
    finalized = shortLog(getStateField(dag.headState, finalized_checkpoint))
  T(
    dag: dag,
    quarantine: quarantine,
    forkChoice: forkChoice,
    onPhase0AttestationAdded: onPhase0Attestation,
    onElectraAttestationAdded: onElectraAttestation
  )

proc addForkChoiceVotes(
    pool: var AttestationPool, slot: Slot,
    attesting_indices: openArray[ValidatorIndex], block_root: Eth2Digest,
    wallTime: BeaconTime) =
  # Add attestation votes to fork choice
  if (let v = pool.forkChoice.on_attestation(
    pool.dag, slot, block_root, attesting_indices, wallTime);
    v.isErr):
      # This indicates that the fork choice and the chain dag are out of sync -
      # this is most likely the result of a bug, but we'll try to keep going -
      # hopefully the fork choice will heal itself over time.
      error "Couldn't add attestation to fork choice, bug?", err = v.error()

func candidateIdx(pool: AttestationPool, slot: Slot,
  isElectra: bool = false): Opt[int] =
  static: doAssert pool.phase0Candidates.len == pool.electraCandidates.len

  let poolLength = if isElectra:
    pool.electraCandidates.lenu64 else: pool.phase0Candidates.lenu64

  if slot >= pool.startingSlot and
      slot < (pool.startingSlot + poolLength):
    Opt.some(int(slot mod poolLength))
  else:
    Opt.none(int)

proc updateCurrent(pool: var AttestationPool, wallSlot: Slot) =
  if wallSlot + 1 < pool.phase0Candidates.lenu64:
    return # Genesis

  static: doAssert pool.phase0Candidates.len == pool.electraCandidates.len
  let newStartingSlot = wallSlot + 1 - pool.phase0Candidates.lenu64

  if newStartingSlot < pool.startingSlot:
    error "Current slot older than attestation pool view, clock reset?",
      startingSlot = pool.startingSlot, newStartingSlot, wallSlot
    return

  # As time passes we'll clear out any old attestations as they are no longer
  # viable to be included in blocks

  if newStartingSlot - pool.startingSlot >= pool.phase0Candidates.lenu64():
    # In case many slots passed since the last update, avoid iterating over
    # the same indices over and over
    pool.phase0Candidates.reset()
    pool.electraCandidates.reset()
  else:
    for i in pool.startingSlot..newStartingSlot:
      pool.phase0Candidates[i.uint64 mod pool.phase0Candidates.lenu64].reset()
      pool.electraCandidates[i.uint64 mod pool.electraCandidates.lenu64].reset()

  pool.startingSlot = newStartingSlot

func oneIndex(
    bits: CommitteeValidatorsBits | ElectraCommitteeValidatorsBits): Opt[int] =
  # Find the index of the set bit, iff one bit is set
  var res = Opt.none(int)
  for idx in 0..<bits.len():
    if bits[idx]:
      if res.isNone():
        res = Opt.some(idx)
      else: # More than one bit set!
        return Opt.none(int)
  res

func toAttestation(entry: AttestationEntry, validation: Phase0Validation):
    phase0.Attestation =
  phase0.Attestation(
    aggregation_bits: validation.aggregation_bits,
    data: entry.data,
    signature: validation.aggregate_signature.finish().toValidatorSig()
  )

func toElectraAttestation(
    entry: AttestationEntry, validation: ElectraValidation):
    electra.Attestation =
  var committee_bits: AttestationCommitteeBits
  committee_bits[int(entry.data.index)] = true

  electra.Attestation(
    aggregation_bits: validation.aggregation_bits,
    committee_bits: committee_bits,
    data: AttestationData(
      slot: entry.data.slot,
      index: 0,
      beacon_block_root: entry.data.beacon_block_root,
      source: entry.data.source,
      target: entry.data.target),
    signature: validation.aggregate_signature.finish().toValidatorSig()
  )

func updateAggregates(entry: var AttestationEntry) =
  # Upgrade the list of aggregates to ensure that there is at least one
  # aggregate (assuming there are singles) and all aggregates have all
  # singles incorporated
  if entry.singles.len() == 0:
    return

  if entry.aggregates.len() == 0:
    # If there are singles, we can create an aggregate from them that will
    # represent our best knowledge about the current votes
    for index_in_committee, signature in entry.singles:
      if entry.aggregates.len() == 0:
        # Create aggregate on first iteration..
        template getInitialAggregate(_: Phase0AttestationEntry):
            untyped {.used.} =
          Phase0Validation(
            aggregation_bits:
              CommitteeValidatorsBits.init(entry.committee_len),
            aggregate_signature: AggregateSignature.init(signature))
        template getInitialAggregate(_: ElectraAttestationEntry):
            untyped {.used.} =
          ElectraValidation(
            aggregation_bits:
              ElectraCommitteeValidatorsBits.init(entry.committee_len),
            aggregate_signature: AggregateSignature.init(signature))
        entry.aggregates.add(getInitialAggregate(entry))
      else:
        entry.aggregates[0].aggregate_signature.aggregate(signature)

      entry.aggregates[0].aggregation_bits.setBit(index_in_committee)
  else:
    # There already exist aggregates - we'll try to top them up by adding
    # singles to them - for example, it may happen that we're being asked to
    # produce a block 4s after creating an aggregate and new information may
    # have arrived by then.
    # In theory, also aggregates could be combined but finding the best
    # combination is hard, so we'll pragmatically use singles only here
    var updated = false
    for index_in_committee, signature in entry.singles:
      for v in entry.aggregates.mitems():
        if not v.aggregation_bits[index_in_committee]:
          v.aggregation_bits.setBit(index_in_committee)
          v.aggregate_signature.aggregate(signature)
          updated = true

    if updated:
      # One or more aggregates were updated - time to remove the ones that are
      # pure subsets of the others. This may lead to quadratic behaviour, but
      # the number of aggregates for the entry is limited by the number of
      # aggregators on the topic which is capped `is_aggregator` and
      # TARGET_AGGREGATORS_PER_COMMITTEE
      var i = 0
      while i < entry.aggregates.len():
        var j = 0
        while j < entry.aggregates.len():
          if i != j and entry.aggregates[i].aggregation_bits.isSubsetOf(
              entry.aggregates[j].aggregation_bits):
            entry.aggregates[i] = entry.aggregates[j]
            entry.aggregates.del(j)
            dec i # Rerun checks on the new `i` item
            break
          else:
            inc j
        inc i

func covers(
    entry: AttestationEntry,
    bits: CommitteeValidatorsBits | ElectraCommitteeValidatorsBits): bool =
  for i in 0..<entry.aggregates.len():
    if bits.isSubsetOf(entry.aggregates[i].aggregation_bits):
      return true
  false

proc addAttestation(
    entry: var AttestationEntry,
    attestation: phase0.Attestation | electra.Attestation,
    signature: CookedSig): bool =
  logScope:
    attestation = shortLog(attestation)

  let
    singleIndex = oneIndex(attestation.aggregation_bits)

  if singleIndex.isSome():
    if singleIndex.get() in entry.singles:
      trace "Attestation already seen",
        singles = entry.singles.len(),
        aggregates = entry.aggregates.len()

      return false

    debug "Attestation resolved",
      singles = entry.singles.len(),
      aggregates = entry.aggregates.len()

    entry.singles[singleIndex.get()] = signature
  else:
    # More than one vote in this attestation
    if entry.covers(attestation.aggregation_bits):
      return false

    # Since we're adding a new aggregate, we can now remove existing
    # aggregates that don't add any new votes
    entry.aggregates.keepItIf(
      not it.aggregation_bits.isSubsetOf(attestation.aggregation_bits))

    entry.aggregates.add(Validation[typeof(entry).CVBType](
      aggregation_bits: attestation.aggregation_bits,
      aggregate_signature: AggregateSignature.init(signature)))

    debug "Aggregate resolved",
      singles = entry.singles.len(),
      aggregates = entry.aggregates.len()

  true

func getAttestationCandidateKey(
    data: AttestationData,
    committee_index: Opt[CommitteeIndex]): Eth2Digest =
  # Some callers might have used for the key just htr(data), so rather than
  # risk some random regression (one was caught in test suite, but there is
  # not any particular reason other code could not have manually calculated
  # the key, too), special-case the phase0 case as htr(data).
  if committee_index.isNone:
    # i.e. no committees selected, so it can't be an actual Electra attestation
    hash_tree_root(data)
  else:
    hash_tree_root([hash_tree_root(data), hash_tree_root(committee_index.get.uint64)])

func getAttestationCandidateKey(
    attestationDataRoot: Eth2Digest, committee_index: CommitteeIndex):
    Eth2Digest =
  hash_tree_root([attestationDataRoot, hash_tree_root(committee_index.uint64)])

proc addAttestation*(
    pool: var AttestationPool,
    attestation: phase0.Attestation | electra.Attestation,
    attesting_indices: openArray[ValidatorIndex],
    signature: CookedSig, wallTime: BeaconTime) =
  ## Add an attestation to the pool, assuming it's been validated already.
  ##
  ## Assuming the votes in the attestation have not already been seen, the
  ## attestation will be added to the fork choice and lazily added to a list of
  ## attestations for future aggregation and block production.
  logScope:
    attestation = shortLog(attestation)

  doAssert attestation.signature == signature.toValidatorSig(),
    "Deserialized signature must match the one in the attestation"

  updateCurrent(pool, wallTime.slotOrZero)

  let candidateIdx = pool.candidateIdx(attestation.data.slot)
  if candidateIdx.isNone:
    debug "Skipping old attestation for block production",
      startingSlot = pool.startingSlot
    return

  template committee_bits(_: phase0.Attestation): auto =
    const res = default(AttestationCommitteeBits)
    res

  # TODO withValue is an abomination but hard to use anything else too without
  #      creating an unnecessary AttestationEntry on the hot path and avoiding
  #      multiple lookups
  template addAttToPool(attCandidates: untyped, entry: untyped, committee_index: untyped) =
    let attestation_data_root = getAttestationCandidateKey(entry.data, committee_index)

    attCandidates[candidateIdx.get()].withValue(attestation_data_root, entry) do:
      if not addAttestation(entry[], attestation, signature):
        return
    do:
      if not addAttestation(
          attCandidates[candidateIdx.get()].mgetOrPut(attestation_data_root, entry),
          attestation, signature):
        # Returns from overall function, not only template
        return

  template addAttToPool(_: phase0.Attestation) {.used.} =
    let newAttEntry = Phase0AttestationEntry(
      data: attestation.data, committee_len: attestation.aggregation_bits.len)
    addAttToPool(pool.phase0Candidates, newAttEntry, Opt.none CommitteeIndex)
    pool.addForkChoiceVotes(
      attestation.data.slot, attesting_indices,
      attestation.data.beacon_block_root, wallTime)

    # Send notification about new attestation via callback.
    if not(isNil(pool.onPhase0AttestationAdded)):
      pool.onPhase0AttestationAdded(attestation)

  template addAttToPool(_: electra.Attestation) {.used.} =
    let
      committee_index = get_committee_index_one(attestation.committee_bits).expect("TODO")
      data =  AttestationData(
        slot: attestation.data.slot,
        index: uint64 committee_index,
        beacon_block_root: attestation.data.beacon_block_root,
        source: attestation.data.source,
        target: attestation.data.target)
    let newAttEntry = ElectraAttestationEntry(
      data: data,
      committee_len: attestation.aggregation_bits.len)
    addAttToPool(pool.electraCandidates, newAttEntry, Opt.some committee_index)
    pool.addForkChoiceVotes(
      attestation.data.slot, attesting_indices,
      attestation.data.beacon_block_root, wallTime)

    # Send notification about new attestation via callback.
    if not(isNil(pool.onElectraAttestationAdded)):
      pool.onElectraAttestationAdded(attestation)

  addAttToPool(attestation)

func covers*(
    pool: var AttestationPool, data: AttestationData,
    bits: CommitteeValidatorsBits): bool =
  ## Return true iff the given attestation already is fully covered by one of
  ## the existing aggregates, making it redundant
  ## the `var` attestation pool is needed to use `withValue`, else Table becomes
  ## unusably inefficient
  let candidateIdx = pool.candidateIdx(data.slot)
  if candidateIdx.isNone:
    return false

  pool.phase0Candidates[candidateIdx.get()].withValue(
      getAttestationCandidateKey(data, Opt.none CommitteeIndex), entry):
    if entry[].covers(bits):
      return true

  false

func covers*(
    pool: var AttestationPool, data: AttestationData,
    bits: ElectraCommitteeValidatorsBits): bool =
  ## Return true iff the given attestation already is fully covered by one of
  ## the existing aggregates, making it redundant
  ## the `var` attestation pool is needed to use `withValue`, else Table becomes
  ## unusably inefficient
  let candidateIdx = pool.candidateIdx(data.slot)
  if candidateIdx.isNone:
    return false

  debugComment "foo"
  # needs to know more than attestationdata now
  #let attestation_data_root = hash_tree_root(data)
  #pool.electraCandidates[candidateIdx.get()].withValue(attestation_data_root, entry):
  #  if entry[].covers(bits):
  #    return true

  false

proc addForkChoice*(pool: var AttestationPool,
                    epochRef: EpochRef,
                    blckRef: BlockRef,
                    unrealized: FinalityCheckpoints,
                    blck: ForkyTrustedBeaconBlock,
                    wallTime: BeaconTime) =
  ## Add a verified block to the fork choice context
  let state = pool.forkChoice.process_block(
    pool.dag, epochRef, blckRef, unrealized, blck, wallTime)

  if state.isErr:
    # This indicates that the fork choice and the chain dag are out of sync -
    # this is most likely the result of a bug, but we'll try to keep going -
    # hopefully the fork choice will heal itself over time.
    error "Couldn't add block to fork choice, bug?",
      blck = shortLog(blck), err = state.error

iterator attestations*(
    pool: AttestationPool, slot: Opt[Slot],
    committee_index: Opt[CommitteeIndex]): phase0.Attestation =
  let candidateIndices =
    if slot.isSome():
      let candidateIdx = pool.candidateIdx(slot.get())
      if candidateIdx.isSome():
        candidateIdx.get() .. candidateIdx.get()
      else:
        1 .. 0
    else:
      0 ..< pool.phase0Candidates.len()

  for candidateIndex in candidateIndices:
    for _, entry in pool.phase0Candidates[candidateIndex]:
      if committee_index.isNone() or entry.data.index == committee_index.get():
        var singleAttestation = phase0.Attestation(
          aggregation_bits: CommitteeValidatorsBits.init(entry.committee_len),
          data: entry.data)

        for index, signature in entry.singles:
          singleAttestation.aggregation_bits.setBit(index)
          singleAttestation.signature = signature.toValidatorSig()
          yield singleAttestation
          singleAttestation.aggregation_bits.clearBit(index)

        for v in entry.aggregates:
          yield entry.toAttestation(v)

iterator electraAttestations*(
    pool: AttestationPool, slot: Opt[Slot],
    committee_index: Opt[CommitteeIndex]): electra.Attestation =
  let candidateIndices =
    if slot.isSome():
      let candidateIdx = pool.candidateIdx(slot.get(), true)
      if candidateIdx.isSome():
        candidateIdx.get() .. candidateIdx.get()
      else:
        1 .. 0
    else:
      0 ..< pool.electraCandidates.len()

  for candidateIndex in candidateIndices:
    for _, entry in pool.electraCandidates[candidateIndex]:
      ## data.index field from phase0 is still being used while we have
      ## 2 attestation pools (pre and post electra). Refer to template addAttToPool
      ## at addAttestation proc.
      if committee_index.isNone() or entry.data.index == committee_index.get():
        var committee_bits: AttestationCommitteeBits
        committee_bits[int(entry.data.index)] = true

        var singleAttestation = electra.Attestation(
          aggregation_bits: ElectraCommitteeValidatorsBits.init(entry.committee_len),
          committee_bits: committee_bits,
          data: AttestationData(
            slot: entry.data.slot,
            index: 0,
            beacon_block_root: entry.data.beacon_block_root,
            source: entry.data.source,
            target: entry.data.target)
        )

        for index, signature in entry.singles:
          singleAttestation.aggregation_bits.setBit(index)
          singleAttestation.signature = signature.toValidatorSig()
          yield singleAttestation
          singleAttestation.aggregation_bits.clearBit(index)

        for v in entry.aggregates:
          yield entry.toElectraAttestation(v)

type
  AttestationCacheKey = (Slot, uint64)
  AttestationCache[CVBType] = Table[AttestationCacheKey, CVBType] ##\
    ## Cache for quick lookup during beacon block construction of attestations
    ## which have already been included, and therefore should be skipped.

func getAttestationCacheKey(ad: AttestationData): AttestationCacheKey =
  # The committee is unique per slot and committee index which means we can use
  # it as key for a participation cache - this is checked in `check_attestation`
  (ad.slot, ad.index)

func add(
    attCache: var AttestationCache, data: AttestationData,
    aggregation_bits: CommitteeValidatorsBits | ElectraCommitteeValidatorsBits) =
  let key = data.getAttestationCacheKey()
  attCache.withValue(key, v) do:
    v[].incl(aggregation_bits)
  do:
    attCache[key] = aggregation_bits

func init(
    T: type AttestationCache, state: phase0.HashedBeaconState, _: StateCache):
    T =
  # Load attestations that are scheduled for being given rewards for
  for i in 0..<state.data.previous_epoch_attestations.len():
    result.add(
      state.data.previous_epoch_attestations[i].data,
      state.data.previous_epoch_attestations[i].aggregation_bits)
  for i in 0..<state.data.current_epoch_attestations.len():
    result.add(
      state.data.current_epoch_attestations[i].data,
      state.data.current_epoch_attestations[i].aggregation_bits)

func init(
    T: type AttestationCache,
    state: altair.HashedBeaconState | bellatrix.HashedBeaconState |
           capella.HashedBeaconState | deneb.HashedBeaconState |
           electra.HashedBeaconState,
    cache: var StateCache): T =
  # Load attestations that are scheduled for being given rewards for
  let
    prev_epoch = state.data.get_previous_epoch()
    cur_epoch = state.data.get_current_epoch()

  template update_attestation_pool_cache(
      epoch: Epoch, participation_bitmap: untyped) =
    let committees_per_slot = get_committee_count_per_slot(
      state.data, epoch, cache)
    for committee_index in get_committee_indices(committees_per_slot):
      for slot in epoch.slots():
        let committee = get_beacon_committee(
            state.data, slot, committee_index, cache)
        var
          validator_bits = typeof(result).B.init(committee.len)
        for index_in_committee, validator_index in committee:
          if participation_bitmap[validator_index] != 0:
            # If any flag got set, there was an attestation from this validator.
            validator_bits[index_in_committee] = true
        result[(slot, committee_index.uint64)] = validator_bits

  # This treats all types of rewards as equivalent, which isn't ideal
  update_attestation_pool_cache(
    prev_epoch, state.data.previous_epoch_participation)
  update_attestation_pool_cache(
    cur_epoch, state.data.current_epoch_participation)

func score(
    attCache: var AttestationCache, data: AttestationData,
    aggregation_bits: CommitteeValidatorsBits | ElectraCommitteeValidatorsBits): int =
  # The score of an attestation is loosely based on how many new votes it brings
  # to the state - a more accurate score function would also look at inclusion
  # distance and effective balance.
  # TODO cache not var, but `withValue` requires it
  let
    key = data.getAttestationCacheKey()
    bitsScore = aggregation_bits.countOnes()

  attCache.withValue(key, xxx):
    doAssert aggregation_bits.len() == xxx[].len(),
      "check_attestation ensures committee length"

    # How many votes were in the attestation minues the votes that are the same
    return bitsScore - aggregation_bits.countOverlap(xxx[])

  # Not found in cache - fresh vote meaning all attestations count
  bitsScore

func check_attestation_compatible*(
    dag: ChainDAGRef,
    state: ForkyHashedBeaconState,
    attestation: SomeAttestation | electra.Attestation |
                 electra.TrustedAttestation): Result[void, cstring] =
  let
    targetEpoch = attestation.data.target.epoch
    compatibleRoot = state.dependent_root(targetEpoch.get_previous_epoch)

    attestedBlck = dag.getBlockRef(attestation.data.target.root).valueOr:
      return err("Unknown `target.root`")
    dependentSlot = targetEpoch.attester_dependent_slot
    dependentBid = dag.atSlot(attestedBlck.bid, dependentSlot).valueOr:
      return err("Dependent root not found")
    dependentRoot = dependentBid.bid.root

  if dependentRoot != compatibleRoot:
    return err("Incompatible shuffling")
  ok()

proc getAttestationsForBlock*(pool: var AttestationPool,
                              state: ForkyHashedBeaconState,
                              cache: var StateCache): seq[phase0.Attestation] =
  ## Retrieve attestations that may be added to a new block at the slot of the
  ## given state
  ## https://github.com/ethereum/consensus-specs/blob/v1.4.0/specs/phase0/validator.md#attestations
  let newBlockSlot = state.data.slot.uint64

  if newBlockSlot < MIN_ATTESTATION_INCLUSION_DELAY:
    return @[] # Too close to genesis

  let
    # Attestations produced in a particular slot are added to the block
    # at the slot where at least MIN_ATTESTATION_INCLUSION_DELAY have passed
    maxAttestationSlot = newBlockSlot - MIN_ATTESTATION_INCLUSION_DELAY
    startPackingTick = Moment.now()

  var
    candidates: seq[tuple[
      score: int, slot: Slot, entry: ptr Phase0AttestationEntry,
      validation: int]]
    attCache = AttestationCache[CommitteeValidatorsBits].init(state, cache)

  for i in 0..<ATTESTATION_LOOKBACK:
    if i > maxAttestationSlot: # Around genesis..
      break

    let
      slot = Slot(maxAttestationSlot - i)
      candidateIdx = pool.candidateIdx(slot)

    if candidateIdx.isNone():
      # Passed the collection horizon - shouldn't happen because it's based on
      # ATTESTATION_LOOKBACK
      break

    for _, entry in pool.phase0Candidates[candidateIdx.get()].mpairs():
      entry.updateAggregates()

      for j in 0..<entry.aggregates.len():
        let attestation = entry.toAttestation(entry.aggregates[j])

        # Filter out attestations that were created with a different shuffling.
        # As we don't re-check signatures, this needs to be done separately
        if not pool.dag.check_attestation_compatible(state, attestation).isOk():
          continue

        # Attestations are checked based on the state that we're adding the
        # attestation to - there might have been a fork between when we first
        # saw the attestation and the time that we added it
        if not check_attestation(
              state.data, attestation, {skipBlsValidation}, cache).isOk():
          continue

        let score = attCache.score(
          entry.data, entry.aggregates[j].aggregation_bits)
        if score == 0:
          # 0 score means the attestation would not bring any votes - discard
          # it early
          # Note; this must be done _after_ `check_attestation` as it relies on
          # the committee to match the state that was used to build the cache
          continue

        # Careful, must not update the attestation table for the pointer to
        # remain valid
        candidates.add((score, slot, addr entry, j))

  # Using a greedy algorithm, select as many attestations as possible that will
  # fit in the block.
  #
  # Effectively https://en.wikipedia.org/wiki/Maximum_coverage_problem which
  # therefore has inapproximability results of greedy algorithm optimality.
  #
  # Some research, also, has been done showing that one can tweak this and do
  # a kind of k-greedy version where each greedy step tries all possible two,
  # three, or higher-order tuples of next elements. These seem promising, but
  # also expensive.
  #
  # For each round, we'll look for the best attestation and add it to the result
  # then re-score the other candidates.
  var res: seq[phase0.Attestation]
  let totalCandidates = candidates.len()
  while candidates.len > 0 and res.lenu64() < MAX_ATTESTATIONS:
    let entryCacheKey = block:
      # Find the candidate with the highest score - slot is used as a
      # tie-breaker so that more recent attestations are added first
      let
        candidate =
          # Fast path for when all remaining candidates fit
          if candidates.lenu64 < MAX_ATTESTATIONS: candidates.len - 1
          else: maxIndex(candidates)
        (_, _, entry, j) = candidates[candidate]

      candidates.del(candidate) # careful, `del` reorders candidates

      res.add(entry[].toAttestation(entry[].aggregates[j]))

      # Update cache so that the new votes are taken into account when updating
      # the score below
      attCache.add(entry[].data,  entry[].aggregates[j].aggregation_bits)

      entry[].data.getAttestationCacheKey

    block:
      # Because we added some votes, it's quite possible that some candidates
      # are no longer interesting - update the scores of the existing candidates
      for it in candidates.mitems():
        # Aggregates not on the same (slot, committee) pair don't change scores
        if it.entry[].data.getAttestationCacheKey != entryCacheKey:
          continue

        it.score = attCache.score(
          it.entry[].data,
          it.entry[].aggregates[it.validation].aggregation_bits)

      candidates.keepItIf:
        # Only keep candidates that might add coverage
        it.score > 0

  let
    packingDur = Moment.now() - startPackingTick

  debug "Packed attestations for block",
    newBlockSlot, packingDur, totalCandidates, attestations = res.len()
  attestation_pool_block_attestation_packing_time.set(
    packingDur.toFloatSeconds())

  res

proc getAttestationsForBlock*(pool: var AttestationPool,
                              state: ForkedHashedBeaconState,
                              cache: var StateCache): seq[phase0.Attestation] =
  withState(state):
    when consensusFork < ConsensusFork.Electra:
      pool.getAttestationsForBlock(forkyState, cache)
    else:
      default(seq[phase0.Attestation])

proc getElectraAttestationsForBlock*(
    pool: var AttestationPool, state: electra.HashedBeaconState,
    cache: var StateCache): seq[electra.Attestation] =
  let newBlockSlot = state.data.slot.uint64

  if newBlockSlot < MIN_ATTESTATION_INCLUSION_DELAY:
    return @[] # Too close to genesis

  let
    # Attestations produced in a particular slot are added to the block
    # at the slot where at least MIN_ATTESTATION_INCLUSION_DELAY have passed
    maxAttestationSlot = newBlockSlot - MIN_ATTESTATION_INCLUSION_DELAY
    startPackingTick = Moment.now()

  var
    candidates: seq[tuple[
      score: int, slot: Slot, entry: ptr ElectraAttestationEntry,
      validation: int]]
    attCache = AttestationCache[ElectraCommitteeValidatorsBits].init(state, cache)

  for i in 0..<ATTESTATION_LOOKBACK:
    if i > maxAttestationSlot: # Around genesis..
      break

    let
      slot = Slot(maxAttestationSlot - i)
      candidateIdx = pool.candidateIdx(slot)

    if candidateIdx.isNone():
      # Passed the collection horizon - shouldn't happen because it's based on
      # ATTESTATION_LOOKBACK
      break

    for _, entry in pool.electraCandidates[candidateIdx.get()].mpairs():
      entry.updateAggregates()

      for j in 0..<entry.aggregates.len():
        let attestation = entry.toElectraAttestation(entry.aggregates[j])

        # Filter out attestations that were created with a different shuffling.
        # As we don't re-check signatures, this needs to be done separately
        if not pool.dag.check_attestation_compatible(state, attestation).isOk():
          continue

        # Attestations are checked based on the state that we're adding the
        # attestation to - there might have been a fork between when we first
        # saw the attestation and the time that we added it
        if not check_attestation(
              state.data, attestation, {skipBlsValidation}, cache, false).isOk():
          continue

        let score = attCache.score(
          entry.data, entry.aggregates[j].aggregation_bits)
        if score == 0:
          # 0 score means the attestation would not bring any votes - discard
          # it early
          # Note; this must be done _after_ `check_attestation` as it relies on
          # the committee to match the state that was used to build the cache
          continue

        # Careful, must not update the attestation table for the pointer to
        # remain valid
        candidates.add((score, slot, addr entry, j))

  # Sort candidates by score use slot as a tie-breaker
  candidates.sort()

  # Using a greedy algorithm, select as many attestations as possible that will
  # fit in the block.
  #
  # Effectively https://en.wikipedia.org/wiki/Maximum_coverage_problem which
  # therefore has inapproximability results of greedy algorithm optimality.
  #
  # Some research, also, has been done showing that one can tweak this and do
  # a kind of k-greedy version where each greedy step tries all possible two,
  # three, or higher-order tuples of next elements. These seem promising, but
  # also expensive.
  #
  # For each round, we'll look for the best attestation and add it to the result
  # then re-score the other candidates.
  var
    candidatesPerBlock: Table[(Eth2Digest, Slot), seq[electra.Attestation]]

  let totalCandidates = candidates.len()
  while candidates.len > 0 and candidatesPerBlock.lenu64() <
      MAX_ATTESTATIONS_ELECTRA * MAX_COMMITTEES_PER_SLOT:
    let entryCacheKey = block:
      let (_, _, entry, j) =
        # Fast path for when all remaining candidates fit
        if candidates.lenu64 < MAX_ATTESTATIONS_ELECTRA:
          candidates[candidates.len - 1]
        else:
          # Get the candidate with the highest score
          candidates.pop()

      #TODO: Merge candidates per block structure with the candidates one
      # and score possible on-chain attestations while collecting candidates
      # (previous loop) and reavaluate cache key definition
      let
        entry2 = block:
          var e2 = entry.data
          e2.index = 0
          e2
        key = (hash_tree_root(entry2), entry.data.slot)
        newAtt = entry[].toElectraAttestation(entry[].aggregates[j])

      candidatesPerBlock.withValue(key, candidate):
        candidate[].add newAtt
      do:
        candidatesPerBlock[key] = @[newAtt]

      # Update cache so that the new votes are taken into account when updating
      # the score below
      attCache.add(entry[].data,  entry[].aggregates[j].aggregation_bits)

      entry[].data.getAttestationCacheKey

    block:
      # Because we added some votes, it's quite possible that some candidates
      # are no longer interesting - update the scores of the existing candidates
      for it in candidates.mitems():
        # Aggregates not on the same (slot, committee) pair don't change scores
        if it.entry[].data.getAttestationCacheKey != entryCacheKey:
          continue

        it.score = attCache.score(
          it.entry[].data,
          it.entry[].aggregates[it.validation].aggregation_bits)

      candidates.keepItIf:
        # Only keep candidates that might add coverage
        it.score > 0

      # Sort candidates by score use slot as a tie-breaker
      candidates.sort()

  # Consolidate attestation aggregates with disjoint committee bits into single
  # attestation
  var res: seq[electra.Attestation]
  for a in candidatesPerBlock.values():
    if a.len > 1:
      let att = compute_on_chain_aggregate(a).valueOr:
        continue
      res.add(att)
    # no on-chain candidates
    else:
      res.add(a)

    if res.lenu64 == MAX_ATTESTATIONS_ELECTRA:
      break

  let packingDur = Moment.now() - startPackingTick

  debug "Packed attestations for block",
    newBlockSlot, packingDur, totalCandidates, attestations = res.len()
  attestation_pool_block_attestation_packing_time.set(
    packingDur.toFloatSeconds())

  res

proc getElectraAttestationsForBlock*(
    pool: var AttestationPool, state: ForkedHashedBeaconState,
    cache: var StateCache): seq[electra.Attestation] =
  withState(state):
    when consensusFork >= ConsensusFork.Electra:
      pool.getElectraAttestationsForBlock(forkyState, cache)
    else:
      default(seq[electra.Attestation])

func bestValidation(
    aggregates: openArray[Phase0Validation | ElectraValidation]): (int, int) =
  # Look for best validation based on number of votes in the aggregate
  doAssert aggregates.len() > 0,
    "updateAggregates should have created at least one aggregate"
  var
    bestIndex = 0
    best = aggregates[bestIndex].aggregation_bits.countOnes()

  for i in 1..<aggregates.len():
    let count = aggregates[i].aggregation_bits.countOnes()
    if count > best:
      best = count
      bestIndex = i
  (bestIndex, best)

func getElectraAggregatedAttestation*(
    pool: var AttestationPool, slot: Slot,
    attestationDataRoot: Eth2Digest, committeeIndex: CommitteeIndex):
    Opt[electra.Attestation] =

  let
    candidateIdx = pool.candidateIdx(slot)
  if candidateIdx.isNone:
    return Opt.none(electra.Attestation)

  pool.electraCandidates[candidateIdx.get].withValue(
      getAttestationCandidateKey(attestationDataRoot, committeeIndex), entry):
    if entry.data.index == committeeIndex.distinctBase:
      entry[].updateAggregates()

      let (bestIndex, _) = bestValidation(entry[].aggregates)

      # Found the right hash, no need to look further
      return Opt.some(entry[].toElectraAttestation(entry[].aggregates[bestIndex]))

  Opt.none(electra.Attestation)

func getElectraAggregatedAttestation*(
    pool: var AttestationPool, slot: Slot, index: CommitteeIndex):
    Opt[electra.Attestation] =
  ## Select the attestation that has the most votes going for it in the given
  ## slot/index
  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.8/specs/electra/validator.md#construct-aggregate
  # even though Electra attestations support cross-committee aggregation,
  # "Set `attestation.committee_bits = committee_bits`, where `committee_bits`
  # has the same value as in each individual attestation." implies that cannot
  # be used here, because otherwise they wouldn't have the same value. It thus
  # leaves the cross-committee aggregation for getElectraAttestationsForBlock,
  # which does do this.
  let candidateIdx = pool.candidateIdx(slot)
  if candidateIdx.isNone:
    return Opt.none(electra.Attestation)

  var res: Opt[electra.Attestation]
  for _, entry in pool.electraCandidates[candidateIdx.get].mpairs():
    doAssert entry.data.slot == slot
    if index != entry.data.index:
      continue

    entry.updateAggregates()

    let (bestIndex, best) = bestValidation(entry.aggregates)

    if res.isNone() or best > res.get().aggregation_bits.countOnes():
      res = Opt.some(entry.toElectraAttestation(entry.aggregates[bestIndex]))

  res

func getPhase0AggregatedAttestation*(
    pool: var AttestationPool, slot: Slot, attestation_data_root: Eth2Digest):
    Opt[phase0.Attestation] =
  let
    candidateIdx = pool.candidateIdx(slot)
  if candidateIdx.isNone:
    return Opt.none(phase0.Attestation)

  pool.phase0Candidates[candidateIdx.get].withValue(
      attestation_data_root, entry):
    entry[].updateAggregates()

    let (bestIndex, _) = bestValidation(entry[].aggregates)

    # Found the right hash, no need to look further
    return Opt.some(entry[].toAttestation(entry[].aggregates[bestIndex]))

  Opt.none(phase0.Attestation)

func getPhase0AggregatedAttestation*(
    pool: var AttestationPool, slot: Slot, index: CommitteeIndex):
    Opt[phase0.Attestation] =
  ## Select the attestation that has the most votes going for it in the given
  ## slot/index
  ## https://github.com/ethereum/consensus-specs/blob/v1.4.0/specs/phase0/validator.md#construct-aggregate
  let candidateIdx = pool.candidateIdx(slot)
  if candidateIdx.isNone:
    return Opt.none(phase0.Attestation)

  var res: Opt[phase0.Attestation]
  for _, entry in pool.phase0Candidates[candidateIdx.get].mpairs():
    doAssert entry.data.slot == slot
    if index != entry.data.index:
      continue

    entry.updateAggregates()

    let (bestIndex, best) = bestValidation(entry.aggregates)

    if res.isNone() or best > res.get().aggregation_bits.countOnes():
      res = Opt.some(entry.toAttestation(entry.aggregates[bestIndex]))

  res

type BeaconHead* = object
  blck*: BlockRef
  safeExecutionBlockHash*, finalizedExecutionBlockHash*: Eth2Digest

proc getBeaconHead*(
    pool: AttestationPool, headBlock: BlockRef): BeaconHead =
  let
    finalizedExecutionBlockHash =
      pool.dag.loadExecutionBlockHash(pool.dag.finalizedHead.blck)
        .get(ZERO_HASH)

    # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.3/fork_choice/safe-block.md#get_safe_execution_payload_hash
    safeBlockRoot = pool.forkChoice.get_safe_beacon_block_root()
    safeBlock = pool.dag.getBlockRef(safeBlockRoot)
    safeExecutionBlockHash =
      if safeBlock.isErr:
        # Safe block is currently the justified block determined by fork choice.
        # If finality already advanced beyond the current justified checkpoint,
        # e.g., because we have selected a head that did not yet realize the cp,
        # the justified block may end up not having a `BlockRef` anymore.
        # Because we know that a different fork already finalized a later point,
        # let's just report the finalized execution payload hash instead.
        finalizedExecutionBlockHash
      else:
        pool.dag.loadExecutionBlockHash(safeBlock.get)
          .get(finalizedExecutionBlockHash)

  BeaconHead(
    blck: headBlock,
    safeExecutionBlockHash: safeExecutionBlockHash,
    finalizedExecutionBlockHash: finalizedExecutionBlockHash)

proc selectOptimisticHead*(
    pool: var AttestationPool, wallTime: BeaconTime): Opt[BeaconHead] =
  ## Trigger fork choice and returns the new head block.
  let newHeadRoot = pool.forkChoice.get_head(pool.dag, wallTime)
  if newHeadRoot.isErr:
    error "Couldn't select head", err = newHeadRoot.error
    return err()

  let headBlock = pool.dag.getBlockRef(newHeadRoot.get()).valueOr:
    # This should normally not happen, but if the chain dag and fork choice
    # get out of sync, we'll need to try to download the selected head - in
    # the meantime, return nil to indicate that no new head was chosen
    warn "Fork choice selected unknown head, trying to sync",
      root = newHeadRoot.get()
    pool.quarantine[].addMissing(newHeadRoot.get())
    return err()

  ok pool.getBeaconHead(headBlock)

proc prune*(pool: var AttestationPool) =
  if (let v = pool.forkChoice.prune(); v.isErr):
    # If pruning fails, it's likely the result of a bug - this shouldn't happen
    # but we'll keep running hoping that the fork chocie will recover eventually
    error "Couldn't prune fork choice, bug?", err = v.error()

func validatorSeenAtEpoch*(pool: AttestationPool, epoch: Epoch,
                           vindex: ValidatorIndex): bool =
  if uint64(vindex) < lenu64(pool.nextAttestationEpoch):
    let mark = pool.nextAttestationEpoch[vindex]
    (mark.subnet > epoch) or (mark.aggregate > epoch)
  else:
    false
