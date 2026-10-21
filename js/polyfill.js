(function(g){
  var C='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  if(!g.atob)g.atob=function(s){s=String(s).replace(/[\t\n\f\r =]/g,'');var o='',b=0,n=0;for(var i=0;i<s.length;i++){b=(b<<6)|C.indexOf(s.charAt(i));n+=6;if(n>=8){n-=8;o+=String.fromCharCode((b>>n)&255)}}return o};
  if(!g.btoa)g.btoa=function(s){s=String(s);var o='';for(var i=0;i<s.length;i+=3){var a=s.charCodeAt(i),b=s.charCodeAt(i+1),c=s.charCodeAt(i+2);o+=C[a>>2]+C[((a&3)<<4)|(b>>4)]+(isNaN(b)?'=':C[((b&15)<<2)|(c>>6)])+(isNaN(c)?'=':C[c&63])}return o};
  if(!g.TextDecoder){g.TextDecoder=function(){};g.TextDecoder.prototype.decode=function(u){var s='';for(var i=0;i<u.length;i++)s+=String.fromCharCode(u[i]);try{return decodeURIComponent(escape(s))}catch(e){return s}}}
  if(!g.TextEncoder){g.TextEncoder=function(){};g.TextEncoder.prototype.encode=function(s){var e=unescape(encodeURIComponent(s)),u=new Uint8Array(e.length);for(var i=0;i<e.length;i++)u[i]=e.charCodeAt(i);return u}}
  if(!g.queueMicrotask)g.queueMicrotask=function(f){Promise.resolve().then(f)};
})(typeof globalThis!=='undefined'?globalThis:this);
