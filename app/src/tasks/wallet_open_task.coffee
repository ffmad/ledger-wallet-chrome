
###
  Procedures declaration
###

openStores = (dongle, raise, done) ->
  ledger.bitcoin.bitid.getAddress (address) =>
    bitIdAddress = address.bitcoinAddress.toString(ASCII)
    dongle.getPublicAddress "0x50DA'/0xBED'/0xC0FFEE'", (pubKey) =>
      if not (pubKey?.bitcoinAddress?) or not (bitIdAddress?)
        logger().error("Fatal error during openStores, missing bitIdAddress and/or pubKey.bitcoinAddress")
        raise(ledger.errors.new(ledger.errors.UnableToRetrieveBitidAddress))
        ledger.app.emit 'wallet:initialization:fatal_error'
        return
      ledger.storage.openStores bitIdAddress, pubKey.bitcoinAddress.value
      ledger.utils.Logger._secureWriter = new ledger.utils.SecureLogWriter(pubKey.bitcoinAddress.toString(ASCII), bitIdAddress, ledger.config.defaultLoggerDaysMax)
      ledger.utils.Logger._secureReader = new ledger.utils.SecureLogReader(pubKey.bitcoinAddress.toString(ASCII), bitIdAddress, ledger.config.defaultLoggerDaysMax)
      done?()
      return
    return

pullStore = (dongle, raise, done) ->
  ledger.storage.sync.pull().then done
  .fail done
  .done()

openHdWallet = (dongle, raise, done) -> ledger.wallet.initialize(dongle, done)

startDerivationTask = (dongle, raise, done) ->
  hdWallet = ledger.wallet.Wallet.instance
  ledger.tasks.AddressDerivationTask.instance.start()
  _.defer =>
    for accountIndex in [0...hdWallet.getAccountsCount()]
      ledger.tasks.AddressDerivationTask.instance.registerExtendedPublicKeyForPath "#{hdWallet.getRootDerivationPath()}/#{accountIndex}'", _.noop
    done?()

openAddressCache = (dongle, raise, done) ->
  cache = new ledger.wallet.Wallet.Cache('cache', ledger.wallet.Wallet.instance)
  cache.initialize =>
    ledger.wallet.Wallet.instance.cache = cache
    done?()

openXpubCache = (dongle, raise, done) ->
  cache = new ledger.wallet.Wallet.Cache('xpub_cache', ledger.wallet.Wallet.instance)
  cache.initialize =>
    ledger.wallet.Wallet.instance.xpubCache = cache
    done?()

refreshHdWallet = (dongle, raise, done) ->
  ledger.wallet.Wallet.instance.initialize ledger.storage.sync.wallet, done

restoreStructure = (dongle, raise, done) ->
  if ledger.wallet.Wallet.instance.isEmpty()
    l "Create Wallet"
    ledger.app.emit 'wallet:initialization:creation'
    ledger.tasks.WalletLayoutRecoveryTask.instance.on 'done', () =>
      ledger.tasks.OperationsSynchronizationTask.instance.startIfNeccessary()
      done?(operation_consumption: yes)
    ledger.tasks.WalletLayoutRecoveryTask.instance.on 'fatal_error', () =>
      ledger.app.emit 'wallet:initialization:failed'
      raise ledger.errors.new(ledger.errors.FatalErrorDuringLayoutWalletRecovery)
    ledger.tasks.WalletLayoutRecoveryTask.instance.startIfNeccessary()
  else if Operation.all().length is 0 and ledger.wallet.Wallet.instance.getAccount(0).getAllAddressesPaths().length isnt 0
    l "Restore wallet"
    for accountIndex in [0...ledger.wallet.Wallet.instance.getAccountsCount()]
      ledger.tasks.AddressDerivationTask.instance.registerExtendedPublicKeyForPath "#{ledger.wallet.Wallet.instance.getRootDerivationPath()}/#{accountIndex}'", _.noop
    ledger.app.emit 'wallet:initialization:creation'
    ledger.tasks.OperationsConsumptionTask.instance.startIfNeccessary()
    ledger.tasks.OperationsConsumptionTask.instance.on 'stop', ->
      ledger.tasks.WalletLayoutRecoveryTask.instance.startIfNeccessary()
      done?(operation_consumption: yes)
  else
    ledger.tasks.WalletLayoutRecoveryTask.instance.startIfNeccessary()
    done?()

completeLayoutInitialization = (dongle, raise, done) ->
  ledger.wallet.Wallet.instance.isInitialized = yes
  done?()

openDatabase = (dongle, raise, done) ->
  ledger.database.init =>
    ledger.database.contexts.open()
    done()

initializeWalletModel = (dongle, raise, done) -> Wallet.initializeWallet done

initializePreferences = (dongle, raise, done) -> ledger.preferences.init done

ProceduresOrder = [
  openStores
  openHdWallet
  startDerivationTask
  openAddressCache
  openXpubCache
  openDatabase
  initializeWalletModel
  pullStore
  refreshHdWallet
  restoreStructure
  completeLayoutInitialization
  initializePreferences
]

###
  End of procedures declaration
###

class ledger.tasks.WalletOpenTask extends ledger.tasks.Task

  steps: ProceduresOrder

  @instance: new @
  @reset: -> @instance = new @

  constructor: ->
    super 'wallet_open_task'
    @_completion = new ledger.utils.CompletionClosure()

  onStart: ->
    super
    raise = (error) =>
      @_completion.failure(error)
      raise.next = _.noop
      @stopIfNeccessary()
    result = _({})
    _.async.each @steps, (step, next, hasNext) =>
      return unless @isRunning()
      raise.next = next
      step ledger.app.dongle, raise, (r) =>
        result.extend(r)
        do raise.next
        @_completion.success(result.value()) unless hasNext

  onStop: ->
    @_completion.failure(ledger.errors.new(ledger.errors.InterruptedTask)) unless @_completion.isCompleted()
    @_completion = new ledger.utils.CompletionClosure()

  onComplete: (callback) -> @_completion.onComplete callback

logger = -> ledger.utils.Logger.getLoggerByTag("WalletOpening")