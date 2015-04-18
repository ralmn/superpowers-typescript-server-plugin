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
      finish []
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

  server_buildScript: (client, callback) =>
    console.log "Compiling scripts..."
    globalNames = []
    globals = {}
    globalBuildDefs = {}

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
        globalBuildDefs["#{pluginName}.d.ts"] = plugin.defs

    # globalNames.push "server-script.ts"
    # globals["server-script.ts"] = @pub.text

    # Make sure the Sup namespace is compiled before everything else
    # globalNames.unshift globalNames.splice(globalNames.indexOf('Sup.ts'), 1)[0]
    # Compile plugin globals
    allGlobals = "#{globalBuildDefs["lib.d.ts"]}\n#{globalBuildDefs["node.d.ts"]}\ndeclare var console, SupEngine, SupRuntime, ioServer"
    jsGlobals = compileTypeScript globalNames, globals, allGlobals, sourceMap: false
    if jsGlobals.errors.length > 0
      errorstr= []
      for error in jsGlobals.errors
        errorstr.push "#{error.file}(#{error.position.line}): #{error.message}"

      callback(errorstr); return

    # Compile game scripts
    concatenatedGlobalBuildDefs = (def for name, def of globalBuildDefs).join ''
    results = compileTypeScript scriptNames, scripts, concatenatedGlobalBuildDefs, sourceMap: true
    if results.errors.length > 0
      errorstr= []
      for error in results.errors
        errorstr.push "#{error.file}(#{error.position.line}): #{error.message}\n"

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


    compile = (files) =>
      cscriptsName = Object.keys(files)
      cscripts = files
      results = compileTypeScript cscriptsName, cscripts, concatenatedGlobalBuildDefs, sourceMap: false
      if results.errors.length > 0
        errorstr= []
        for error in results.errors
          errorstr.push "#{error.file}(#{error.position.line}): #{error.message}\n"
        callback(errorstr)
        return
      console.log results      
      code = jsGlobals.script + results.script
      # console.log code
      if @child?
        @child.kill("SIGHUP")

      @child = child_process.fork(__dirname + "/../run.js", [], {silent: true})
      if @child?.stdout?
        @child.stdout.on 'data', (data) =>
          client.socket.emit "stdout:#{@id}", data.toString()

        @child.stderr.on 'data', (data) =>
          client.socket.emit "stderr:#{@id}", data.toString()
        @child.send({action: 'start', code: code})
        callback "Script started !"
      else
        callback "Starting error"

    scriptsCode = {}
    remainingAssetsToLoad = Object.keys(@serverData.entries.byId).length
    assetsLoading = 0

    @serverData.entries.walk (entry) =>
      remainingAssetsToLoad--
      if entry.type != 'server-script'
        if remainingAssetsToLoad == 0 and assetsLoading == 0
          compile(scriptsCode) 
        return 
      assetsLoading++
      @serverData.assets.acquire entry.id, null, (err, asset) =>
        assetsLoading--
        scriptsCode[entry.name+ '.ts'] = asset.pub.text
        if remainingAssetsToLoad == 0 and assetsLoading == 0
          compile(scriptsCode) 

    #code = jsGlobals.script + scriptsCode.join '\n'#results.script #+ "\n//# sourceMappingURL=#{url}"



    
    return
  client_buildScript: ->
    return

  client_killScript: ->
    return
  server_killScript: (client, callback) ->
    if @child?
      client.socket.emit "script-status:#{@id}", "Kill by user"
      @child.kill("SIGHUP")
      callback null
    else
      callback "not child"
