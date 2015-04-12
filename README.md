#Superpowers Typescript Server plugin

This plugin for [Superpowers, the extensible HTML5 2D+3D game engine](http://sparklinlabs.com) brings a server script for exemple multiplayer script with socket.io plugin 


## Installation

[Download the latest release](https://github.com/ralmn/superpowers-typescript-server-plugin/releases) and unzip it.

Rename the folder if you want then move it inside `app/plugins/ralmn/`.

Finally restart your server.

## Script usage

``` 
  var txt = Sup.getActor('TextActor');
    txt.textRenderer.setText("Hello");
    txt.textRenderer.setTextColor("rgba(255,0,0,1)");
    txt.textRenderer.setFont("Arial");
    txt.textRenderer.setFontSize(32);
    
  
```
