gulp = require 'gulp'
tasks = [ 'jade']

# Jade
jade = require 'gulp-jade'
gulp.task 'jade', -> gulp.src('./editors/**/index.jade').pipe(jade()).pipe(gulp.dest('./public/editors'))

# Browserify
browserify = require 'browserify'
vinylSourceStream = require 'vinyl-source-stream'
makeBrowserify = (source, destination, output) ->
  gulp.task "#{output}-browserify", ->
    bundler = browserify source, extensions: ['.coffee']
    bundler.transform 'coffeeify'
    bundler.transform 'brfs'
    bundle = -> bundler.bundle().pipe(vinylSourceStream("#{output}.js")).pipe gulp.dest(destination)
    bundle()

  tasks.push "#{output}-browserify"

makeBrowserify "./data/index.coffee", "./public", "data"
# makeBrowserify "./runtime/index.coffee", "./public", "runtime"
makeBrowserify "./api/index.coffee", "./public", "api"
makeBrowserify "./editors/#{editor}/index.coffee", "./public/editors", "#{editor}/index" for editor in require('fs').readdirSync './editors'

# All
gulp.task 'default', tasks

gulp.task "watch", ->
  gulp.watch './**/index.jade', ["jade"]
  gulp.watch "./api/*", ["api-browserify"]
  gulp.watch "./data/*.coffee", ["data-browserify"]
  # gulp.watch "./runtime/*.coffee", ["runtime-browserify"]
  gulp.watch "./editors/server-script/*.coffee", tasks
