
resolveRelationship = (object, relationship) ->
  Class = window[relationship.Class]
  switch relationship.type
    when 'many_one'
      object._collection.getRelationshipView(object, relationship).modelize()
    when 'one_many'
      Class.find(_.object([Class.getBestIdentifierName()], [object.get("#{relationship.name}_id")]), object._context).data()[0]
    when 'one_one'
      Class.find(_.object([Class.getBestIdentifierName()], [object.get("#{relationship.name}_id")]), object._context).data()[0]
    when 'many_many'
      object._collection.getRelationshipView(object, relationship).modelize()


class @ledger.database.Model extends @EventEmitter

  constructor: (context, base) ->
    throw 'Model can not be build without a context' unless context?
    @_context = context
    @_collection = context.getCollection(@getCollectionName())
    @_object = base
    @_needsUpdate = if @isInserted() then no else yes
    @_deleted = no

  get: (key) ->
    if @getRelationships()?[key]?
      relationship = @getRelationships()[key]
      result = resolveRelationship(@, relationship)
      result = @_pendingRelationships?[key] unless result?
      result
    else
      @_object?[key]

  getId: () -> @getBestIdentifier()
  getLokiId: -> @_object?['$loki']
  @getBestIdentifierName: -> @_bestIdentifier

  getBestIdentifierName: -> @constructor.getBestIdentifierName()

  getBestIdentifier: -> @_object?[@constructor.getBestIdentifierName()]

  set: (key, value) ->
    @_object ?= {}
    if @getRelationships()?[key]?
      throw "Attempt to set a value to a '#{@getRelationships()[key].type.replace('_', ':')}'" if _.contains(['many_one', 'many_many'], @getRelationships()[key].type)
      @_pendingRelationships ?= {}
      @_pendingRelationships[key] = {}
      @_pendingRelationships[key].add = value if value?
      @_pendingRelationships[key].remove = {} unless value?
    else
      @_object[key] = value
    @_needsUpdate = yes
    @

  remove: (key, value) ->
    unless value?
      return @set(key, null)
    if @getRelationships()?[key]?
      throw "Attempt to remove a value to a '#{@getRelationships()[key].type.replace('_', ':')}'" if _.contains(['one_one', 'one_many'], @getRelationships()[key].type)
      @_pendingRelationships ?= {}
      @_pendingRelationships[key] ?= {}
      @_pendingRelationships[key].remove ?= []
      @_pendingRelationships[key].remove.push value
    else if _.isArray(@_object[key])
      if _.contains(@_object[key], value)
        @_object[key] = _.without(@_object[key], value)
    @_needsUpdate = yes
    @

  add: (key, value) ->
    if @getRelationships()?[key]?
      throw "Attempt to add a value to a '#{@getRelationships()[key].type.replace('_', ':')}'" if _.contains(['one_one', 'one_many'], @getRelationships()[key].type)
      @_pendingRelationships ?= {}
      @_pendingRelationships[key] ?= {}
      @_pendingRelationships[key].add ?= []
      @_pendingRelationships[key].add.push value
    else if not @_object[key]? or _.isArray(@_object[key])
      @_object[key] ?= []
      unless _.contains(@_object[key], value)
        @_object[key].push value
    @_needsUpdate = yes
    @

  save: () ->
    return @ unless @hasChange()
    if @isInserted() and @onUpdate() isnt false
      @_commitPendingRelationships()
      @_collection.update this
    else if @onInsert() isnt false
      @_collection.insert this
      @_commitPendingRelationships()
      @_needsUpdate = no
    @

  delete: () ->
    if not @_deleted and @onDelete() isnt false
      if @getRelationships()?
        for relationshipName, relationship of @getRelationships()
          switch relationship.onDelete
            when 'destroy'
              switch relationship.type
                when 'many_one'
                  item.delete() for item in @get(relationshipName)
                when 'one_one'
                  @get(relationshipName).delete()
                when 'one_many'
                  @get(relationshipName).delete()
                when 'many_many' then throw 'many:many relastionships are not implemented yet'
            when 'nullify'
              switch relationship.type
                when 'many_one'
                  item.set(relationship.inverse, null).save() for item in @get(relationshipName)
                when 'one_one'
                  @get(relationshipName).set(relationship.inverse, null)
                when 'many_many' then throw 'many:many relastionships are not implemented yet'
      @_deleted = true
      @_collection.remove this
      return

  refresh: () ->
    @_collection.refresh this
    @

  # Called before insertion
  # @return Return false if you want to cancel the insertion
  onInsert: () ->

  # Called before delete
  # @return Return false if you want to cancel the deletion
  onDelete: () ->

  # Called before update
  # @return Return false if you want to cancel the update
  onUpdate: () ->

  # Called before a model is added to another model as a many_* relationship
  onAdd: () ->

  # Called before a model is removed from another model as a many_* relationship
  onRemove: () ->

  isInserted: () -> if @_object?.meta? then yes else no

  isDeleted: () -> @_deleted

  hasChange: () -> @_needsUpdate

  getRelationships: () -> @constructor._relationships

  _getModelValue: (relationship, value) ->
    ValueClass = window[relationship.Class]
    unless _(value).isKindOf ValueClass
      value = new ValueClass(@_context, value)
      value.save()
    value

  _commitAddPendingRelationship: (pending, relationship) ->
    switch relationship.type
      when 'many_one'
        for v in pending.add
          value = @_getModelValue(relationship, v)
          value.set("#{relationship.inverse}_id", @getBestIdentifier())
          value.save()
      when 'one_many'
        value = @_getModelValue(relationship, pending.add)
        @_object["#{relationship.name}_id"] = value.getBestIdentifier()
        @_collection.update this
      when 'one_one'
        value = @_getModelValue(relationship, pending.add)
        @_object["#{relationship.name}_id"] = value.getBestIdentifier()
        value.set("#{relationship.inverse}_id", @getBestIdentifier())
        value.save()
        @_collection.update this
      when 'many_many' then throw 'many:many relationships are not implemented yet'

  _commitRemovePendingRelationship: (pending, relationship) ->
    switch relationship.type
      when 'many_one'
        for v in pending.remove
          value = @_getModelValue(relationship, v)
          value.set("#{relationship.inverse}_id", null)
          value.save()
      when 'one_many'
        @_object["#{relationship.name}_id"] = null
        @_collection.update this
      when 'one_one'
        value = @get(relationship.name)
        @_object["#{relationship.name}_id"] = value.getBestIdentifier()
        value.set("#{relationship.inverse}_id", null)
        value.save()
        @_collection.update this
      when 'many_many' then throw 'many:many relationships are not implemented yet'

  _commitPendingRelationships: () ->
    return unless @_pendingRelationships?
    for relationshipName, pending of @_pendingRelationships
      relationship = @getRelationships()[relationshipName]
      continue unless relationship?
      if pending.add?
        @_commitAddPendingRelationship(pending, relationship)
      if pending.remove?
        @_commitRemovePendingRelationship(pending, relationship)
    @_pendingRelationships = null

  @create: (base, context = ledger.database.contexts.main) ->
    [bestIdentifier] = _(@_indexes).filter (i) => i.options.unique is yes and i.field is @getBestIdentifierName() and i.options.auto is yes
    (base ||= {})[bestIdentifier.field] ?= @uniqueId(bestIdentifier.field) if bestIdentifier?
    new @ context, base

  @uniqueId: (prefix = "") -> ledger.crypto.SHA256.hashString(prefix + (byte.toString(16) for byte in crypto.getRandomValues(new Uint8Array(32))).join(''))


  @findById: (id, context = ledger.database.contexts.main) ->
    if @getBestIdentifierName() is '$loki'
      context.getCollection(@getCollectionName()).get(id)
    else
      @find(_.object([@getBestIdentifierName()], [id]), context).data()[0]

  @findOrCreate: (query, base, context = ledger.database.contexts.main) ->
    if _.isKindOf(base, ledger.database.contexts.Context)
      context = base
      base = undefined
    if _.isObject query
      object = @find(query, context).data()[0]
      base ?= {}
      _.extend(base, query)
    else
      object = @findById(query, context)
    object = @create base, context unless object?
    object

  @chain: (context = ledger.database.contexts.main) -> context.getCollection(@getCollectionName()).query()

  @find: (query, context = ledger.database.contexts.main) ->
    chain = @chain(context)
    chain.find(query) if query?
    chain

  @where: (filterFunction, context = ledger.database.contexts.main) ->
    chain = @chain(context)
    chain.where(filterFunction) if filterFunction?
    chain

  @all: (context = ledger.database.contexts.main) -> context.getCollection(@getCollectionName()).query().data()

  # Relationship creator
  @has: (relationshipDeclaration) ->
    if relationshipDeclaration['many']?
      @_createRelationship(relationshipDeclaration, 'many')
    else if relationshipDeclaration['one']
      @_createRelationship(relationshipDeclaration, 'one')

  @_createRelationship: (relationshipDeclaration, myType) ->
    if myType is 'many'
      r = if _.isArray(relationshipDeclaration['many']) then relationshipDeclaration['many'] else [relationshipDeclaration['many'], _.str.capitalize(_.singularize(_.str.camelize(relationshipDeclaration['many'])))]
    else
      r = if _.isArray(relationshipDeclaration['one']) then relationshipDeclaration['one'] else [relationshipDeclaration['one'], _.str.capitalize(_.str.camelize(relationshipDeclaration['one']))]
    if relationshipDeclaration['forOne']?
      i = [relationshipDeclaration['forOne'], 'one']
    else if relationshipDeclaration['forMany']?
      i =  [relationshipDeclaration['forMany'], 'many']
    else
      i = [_.str.underscored(@name).toLocaleLowerCase(), 'one']
    sort = null
    if relationshipDeclaration['sortBy']?
      sort = relationshipDeclaration['sortBy']
      if _(sort).isArray()
        finalSort = []
        normalizedIndex = 0
        for index in [0..sort.length]
          value = sort[index]
          if normalizedIndex % 2 == 0
            finalSort.push [value] if value?
          else if _(value).isString() and !value.match(/^(asc|desc)$/)
            normalizedIndex += 1
            finalSort[finalSort.length - 1][1] = no
            finalSort.push [value]
          else
            finalSort[finalSort.length - 1][1] = if !value? or value is 'desc' then yes else no
          normalizedIndex += 1
        sort = finalSort
      else if !_(sort).isFunction()
        sort = [[sort, no]]
    onDelete = if relationshipDeclaration['onDelete']? then relationshipDeclaration['onDelete'] else 'nullify'
    unless _.contains(['nullify', 'destroy', 'none'], onDelete)
      e "Relationship #{@name}::#{r[0]} delete rule '#{onDelete}' is not valid. Please review this. Should be either 'nullify', 'none' or 'destroy'"
      onDelete = 'nullify'
    relationship = name: r[0], type: "#{myType}_#{i[1]}", inverse: i[0], Class: r[1], inverseType: "#{i[1]}_#{myType}", sort: sort, onDelete: onDelete, sync: relationshipDeclaration.sync
    try
      if relationshipDeclaration.sync is true
        if myType is 'one'
          @sync "#{relationship.name}_id"
        else
          e "Cannot synchronize relationship #{@name}-#{relationship.name}, please synchronize relationship #{relationship.name}-#{@name}"
    catch er
      e er
    @_relationships ?= {}
    @_relationships[relationship.name] = relationship

  @commitRelationship: () ->
    throw 'This methods should only be called once by Model' unless @ is Model
    # Ensure all relationships are bound and consistent between models (each relationship are sets in both directions)
    for ClassName, Class of @AllModelClasses()
      Class._synchronizedIndex = _(Class._indexes).filter (i) -> i.options?.sync is yes
      e "Found multiple synchronized indexes in declaration of model #{ClassName}" if Class._synchronizedIndex.length > 1
      [Class._synchronizedIndex] = Class._synchronizedIndex
      e "Found synchronized property without any synchronized index. Add @index 'index_name', sync: yes. In the declaration of #{ClassName}" if Class._synchronizedProperties?.length > 0 and not Class._synchronizedIndex
      for relationshipName, relationship of Class._relationships
        InverseClass = window[relationship.Class]
        if InverseClass._relationships? and InverseClass._relationships[relationship.inverse]?.inverse is relationship.name and InverseClass._relationships[relationship.inverse]?.type is relationship.inverseType and InverseClass._relationships[relationship.inverse]?.Class is ClassName
          continue
        else if not InverseClass._relationships?[relationship.inverse]
          InverseClass._relationships ?= {}

          InverseClass._relationships[relationship.inverse] = name: relationship.inverse, type: relationship.inverseType, inverse:relationship.name, Class: ClassName, inverseType: relationship.type, onDelete: 'nullify'
        else
          e "Bad relationship #{relationship.name} <-> #{relationship.inverse}. You must absolutely check for errors for classes #{ClassName} and #{relationship.Class}"

      Class._bestIdentifier =
        if Class._synchronizedIndex?
          Class._synchronizedIndex.field
        else if (bestId = _(Class._indexes).find((i) -> i.options['unique']? is true))?.length is 1
          bestId[0]
        else
          '$loki'

  @index: (field, options = {}) ->
    @_indexes ?= []
    @_indexes.push {field, options}

  @sync: (propertyName, options = {}) ->
    @_synchronizedProperties ?= []
    @_synchronizedProperties.push {property: propertyName, options}

  @init: () ->
    ledger.database.Model._allModelClasses ?= {}
    ledger.database.Model._allModelClasses[@name] = @

  @getCollectionName: () -> @name

  getCollectionName: () -> @constructor.getCollectionName()

  @AllModelClasses: () -> @_allModelClasses

  getSynchronizedProperties: ->
    return {} if not @_object? or not @constructor._synchronizedIndex?
    object = {}
    object[@constructor.getBestIdentifierName()] = @_object[@constructor.getBestIdentifierName()]
    for property in (@constructor._synchronizedProperties or [])
      object[property.property] = @_object[property.property]
    object

  @getSynchronizedPropertiesNames: -> (if @_synchronizedIndex? then [@_synchronizedIndex.field] else []).concat (property.property for property in (@_synchronizedProperties or []))

  @hasSynchronizedProperties: -> @_synchronizedIndex? and @_synchronizedIndex isnt undefined
  hasSynchronizedProperties: -> @constructor.hasSynchronizedProperties()

  serialize: () ->
    json = $.extend {}, @_object
    delete json['meta']
    delete json['objType']
    delete json['$loki']
    return json
