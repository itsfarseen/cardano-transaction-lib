/* global BROWSER_RUNTIME */

let lib;
if (typeof BROWSER_RUNTIME != "undefined" && BROWSER_RUNTIME) {
  lib = require("@emurgo/cardano-serialization-lib-browser");
} else {
  lib = require("@emurgo/cardano-serialization-lib-nodejs");
}
lib = require("csl-runtime-gc")(lib);

exports._fromBytes = helper => name => bytes => {
  try {
    return helper.valid(lib[name].from_bytes(bytes));
  } catch (e) {
    return helper.error(name + ".from_bytes() raised " + e);
  }
};
