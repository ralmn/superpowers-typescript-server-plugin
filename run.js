ioServer = require ("socket.io")
process.on('message',function(m){
  if(m['action'] != null && m['action'] == "start")
    eval( m.code)
})
module.exports = function(){
}

