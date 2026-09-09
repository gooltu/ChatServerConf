/*global global*/

import * as Strophe from './core';
import * as bosh from './bosh';
import * as websocket from './websocket';
import xmldom from 'xmldom';
import base64 from 'base-64';
import roster from './strophe.roster'

global.DOMParser = xmldom.DOMParser;
global.document = new DOMParser().parseFromString('<xml></xml>', 'text/xml');
global.atob = base64.decode;
global.btoa = base64.encode;
console.log('roster')
console.log(roster)


global.Strophe = Strophe.default.Strophe;
global.$build = Strophe.default.$build;
global.$iq = Strophe.default.$iq;
global.$msg = Strophe.default.$msg;
global.$pres = Strophe.default.$pres;

export { default } from './core';
