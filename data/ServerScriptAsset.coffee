OT = require 'operational-transform'
fs = require 'fs'
vm = require 'vm'
path = require 'path'
async = require 'async'
convert = require 'convert-source-map'
combine = require 'combine-source-map'
child_process = require 'child_process'
_ = require 'lodash'

if ! window?
  serverRequire = require
  compileTypeScript = serverRequire '../runtime/compileTypeScript'
  ts = serverRequire 'typescript'
  globalDefs = ""

  actorComponentAccessors = []
  plugins = SupAPI.contexts["typescript-server"].plugins 
  for pluginName, plugin of plugins
    globalDefs += plugin.defs if plugin.defs?
    if plugin.exposeActorComponent?
      actorComponentAccessors.push "#{plugin.exposeActorComponent.propertyName}: #{plugin.exposeActorComponent.className};"

  globalDefs = globalDefs.replace "// INSERT_COMPONENT_ACCESSORS", actorComponentAccessors.join('\n    ')

module.exports = class ServerScriptAsset extends SupCore.data.base.Asset

  @schema:
    text: { type: 'string' }
    draft: { type: 'string' }
    revisionId: { type: 'integer' }

  constructor: (id, pub, serverData) ->
    @document = new OT.Document
    super id, pub, @constructor.schema, serverData

  init: (options, callback) ->
    # Transform "script asset name" into "ServerScriptAssetNameBehavior"
    behaviorName = options.name.trim()
    behaviorName = behaviorName.slice(0, 1).toUpperCase() + behaviorName.slice(1)

    loop
      index = behaviorName.indexOf(' ')
      break if index == -1

      behaviorName =
        behaviorName.slice(0, index) +
        behaviorName.slice(index + 1, index + 2).toUpperCase() +
        behaviorName.slice(index + 2)

    behaviorName += "Behavior" if ! _.endsWith(behaviorName, "Behavior")

    defaultContent = ""
      

    @pub =
      text: defaultContent
      draft: defaultContent
      revisionId: 0

    @serverData.resources.acquire 'behaviorProperties', null, (err, behaviorProperties) =>
      if ! behaviorProperties.pub.behaviors[behaviorName]?
        behaviors = {}
        behaviors[behaviorName] = []
        behaviorProperties.setScriptBehaviors @id, behaviors

      @serverData.resources.release 'behaviorProperties', null
      super options, callback; return
    return

  setup: ->
    @document.text = @pub.draft
    @document.operations.push 0 for i in [0...@pub.revisionId] by 1

    @hasDraft = @pub.text != @pub.draft
    return

  restore: ->
    if @hasDraft then @emit 'setDiagnostic', 'draft', 'info'
    return

  destroy: (callback) ->
    @serverData.resources.acquire 'behaviorProperties', null, (err, behaviorProperties) =>
      behaviorProperties.clearScriptBehaviors @id
      @serverData.resources.release 'behaviorProperties', null
      callback(); return
    return

  load: (assetPath) ->
    fs.readFile path.join(assetPath, "asset.json"), { encoding: 'utf8' }, (err, json) =>
      @pub = JSON.parse json

      fs.readFile path.join(assetPath, "server-script.txt"), { encoding: 'utf8' }, (err, text) =>
        @pub.text = text

        fs.readFile path.join(assetPath, "draft.txt"), { encoding: 'utf8' }, (err, draft) =>
          # Temporary asset migration
          draft ?= @pub.text

          @pub.draft = draft
          @setup()
          @emit 'load'
        return
      return
    return

  save: (assetPath, callback) ->
    text = @pub.text; delete @pub.text
    draft = @pub.draft; delete @pub.draft

    json = JSON.stringify @pub, null, 2

    @pub.text = text
    @pub.draft = draft

    fs.writeFile path.join(assetPath, "asset.json"), json, { encoding: 'utf8' }, (err) ->
      if err? then callback err; return
      fs.writeFile path.join(assetPath, "server-script.txt"), text, { encoding: 'utf8' }, (err) ->
        if err? then callback err; return
        fs.writeFile path.join(assetPath, "draft.txt"), draft, { encoding: 'utf8' }, callback
    return

  server_editText: (client, operationData, revisionIndex, callback) ->
    if operationData.userId != client.id then callback 'Invalid client id'; return

    operation = new OT.TextOperation
    if ! operation.deserialize operationData then callback 'Invalid operation data'; return

    try operation = @document.apply operation, revisionIndex
    catch err then callback "Operation can't be applied"; return

    @pub.draft = @document.text
    @pub.revisionId++

    callback null, operation.serialize(), @document.operations.length - 1

    if ! @hasDraft
      @hasDraft = true
      @emit 'setDiagnostic', 'draft', 'info'

    @emit 'change'
    return

  client_editText: (operationData, revisionIndex) ->
    operation = new OT.TextOperation
    operation.deserialize operationData
    @document.apply operation, revisionIndex
    @pub.draft = @document.text
    @pub.revisionId++
    return

  server_saveText: (client, callback) ->
    @pub.text = @pub.draft

    scriptNames = []
    scripts = {}
    ownScriptName = ""

    finish = (errors) =>
      callback null, errors

      if @hasDraft
        @hasDraft = false
        @emit 'clearDiagnostic', 'draft'

      @emit 'change'
      return

    compile = =>
      try results = compileTypeScript scriptNames, scripts, globalDefs+ "declare var console", sourceMap: false
      catch e then finish [ { file: "errorOnLoad", position: { line: 1, character: 1 }, message: e.message } ]; return

      ownErrors = ( error for error in results.errors when error.file == ownScriptName )
      if ownErrors.length > 0 then finish ownErrors; return

      libSourceFile = results.program.getSourceFile("lib.d.ts")


      behaviors = {}
      for symbolName, symbol of results.program.getSourceFile(ownScriptName).locals
        continue if (symbol.flags & ts.SymbolFlags.Class) != ts.SymbolFlags.Class

        baseTypeNode = ts.getClassBaseTypeNode(symbol.valueDeclaration)
        continue if ! baseTypeNode?

        typeSymbol = results.typeChecker.getSymbolAtLocation baseTypeNode.typeName
        continue if typeSymbol != supTypeSymbols["Sup.Behavior"]

        properties = behaviors[symbolName] = []

        for memberName, member of symbol.members
          # Skip non-properties
          continue if (member.flags & ts.SymbolFlags.Property) != ts.SymbolFlags.Property

          # Skip static, private and protected members
          modifierFlags = member.valueDeclaration.modifiers?.flags
          continue if modifierFlags? and (modifierFlags & (ts.NodeFlags.Private | ts.NodeFlags.Protected | ts.NodeFlags.Static)) != 0

          # TODO: skip members annotated as "non-customizable"

          type = results.typeChecker.getTypeAtLocation(member.valueDeclaration)
          typeName = null # "unknown"
          symbol = type.getSymbol()
          if type.intrinsicName?
            typeName = type.intrinsicName

          if typeName?
            properties.push { name: memberName, type: typeName }

      @serverData.resources.acquire 'behaviorProperties', null, (err, behaviorProperties) =>
        behaviorProperties.setScriptBehaviors @id, behaviors
        @serverData.resources.release 'behaviorProperties', null
        finish []; return
      return

    remainingAssetsToLoad = Object.keys(@serverData.entries.byId).length
    assetsLoading = 0
    @serverData.entries.walk (entry) =>
      remainingAssetsToLoad--
      if entry.type != "server-script"
        compile() if remainingAssetsToLoad == 0 and assetsLoading == 0
        return

      name = "#{@serverData.entries.getPathFromId(entry.id)}.ts"
      scriptNames.push name
      assetsLoading++
      @serverData.assets.acquire entry.id, null, (err, asset) =>
        scripts[name] = asset.pub.text
        ownScriptName = name if asset == @

        @serverData.assets.release entry.id
        assetsLoading--

        compile() if remainingAssetsToLoad == 0 and assetsLoading == 0
        return
      return
    return

  client_saveText: ->
    @pub.text = @pub.draft
    return

  server_buildScript: (client, callback) ->
    console.log "Compiling scripts..."
    globalNames = []
    globals = {}
    globalDefs = {}

    scriptNames = []
    scripts = {}
    # Plug component accessors exposed by plugins into Sup.Actor class
    for pluginName, plugin of SupAPI.contexts["typescript-server"].plugins
      if plugin.exposeActorComponent?
        continue
      if plugin.code?
        globalNames.push "#{pluginName}.ts"
        globals["#{pluginName}.ts"] = plugin.code

      if plugin.defs?
        globalDefs["#{pluginName}.d.ts"] = plugin.defs

    globalNames.push "server-script.ts"
    globals["server-script.ts"] = @pub.text

    # Make sure the Sup namespace is compiled before everything else
    # globalNames.unshift globalNames.splice(globalNames.indexOf('Sup.ts'), 1)[0]
    # Compile plugin globals
    jsGlobals = compileTypeScript globalNames, globals, "#{globalDefs["lib.d.ts"]}\n#{globalDefs["node.d.ts"]}\ndeclare var console, SupEngine, SupRuntime, ioServer", sourceMap: false
    if jsGlobals.errors.length > 0
      errorstr= ["error1"]
      for error in jsGlobals.errors
        errorstr.push "#{error.file}(#{error.position.line}): #{error.message}"
        console.log "#{error.file}(#{error.position.line}): #{error.message}"

      callback(errorstr); return

    # Compile game scripts
    concatenatedGlobalDefs = (def for name, def of globalDefs).join ''
    results = compileTypeScript scriptNames, scripts, concatenatedGlobalDefs, sourceMap: true
    if results.errors.length > 0
      errorstr= ["error2"]
      for error in results.errors
        errorstr.push "#{error.file}(#{error.position.line}): #{error.message}\n"
        console.log "#{error.file}(#{error.position.line}): #{error.message}"

      callback(errorstr); return

    console.log "Compilation successful!"

    # Prepare source maps
    getLineCounts = (string) =>
      count = 1; index = -1
      loop
        index = string.indexOf "\n", index + 1
        break if index == -1
        count++
      count

    line = getLineCounts(jsGlobals.script)
    combinedSourceMap = combine.create('bundle.js')
    for file in results.files
      comment = convert.fromObject( results.sourceMaps[file.name] ).toComment()
      combinedSourceMap.addFile( { sourceFile: file.name, source: file.text + "\n#{comment}" }, {line} )
      line += ( getLineCounts( file.text ) )

    convertedSourceMap = convert.fromBase64(combinedSourceMap.base64()).toObject();
    # url = URL.createObjectURL(new Blob([ JSON.stringify(convertedSourceMap) ]));
    code = jsGlobals.script + results.script #+ "\n//# sourceMappingURL=#{url}"
    # code = "var ioSever = require('socket.io'); " +code;

    if @child?
      @child.kill("SIGHUP")
    @child = child_process.fork("./run.coffee", [], {silent: true})
    @child.send({action: 'start', code: code})
    callback "Script started !"
    @child.stdout.on 'data', (data) =>
      client.socket.emit "stdout:#{@id}", data.toString()
      console.log("stdout:#{@id} :"+data);
    return
  client_buildScript: ->
    return

  client_killScript: ->
    return
  server_killScript: (client, callback) ->
    if @child?
      client.socket.emit "stdout:#{@id}", "Kill by user"
      @child.kill("SIGHUP")
      callback null
    else
      callback "not child"
