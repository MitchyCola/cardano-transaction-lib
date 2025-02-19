// NOTE: Adopted from https://github.com/AlexaDeWit/purescript-text-encoding/blob/master/src/Data/TextDecoding.js
// See https://github.com/Plutonomicon/cardano-transaction-lib/issues/544
'use strict';

// `TextDecoder` is not available in `node`, use polyfill in that case
let OurTextDecoder;
if (typeof BROWSER_RUNTIME == 'undefined' || !BROWSER_RUNTIME) {
    OurTextDecoder = require('util').TextDecoder;
} else {
    OurTextDecoder = TextDecoder;
};

exports._decodeUtf8 = buffer => left => right => {
    let decoder = new OurTextDecoder("utf-8", {fatal: true}); // Without fatal=true it never fails

    try {
        return right(decoder.decode(buffer));
    } catch (err) {
        return left(err.toString());
    }
};

// FIXME: https://github.com/Plutonomicon/cardano-transaction-lib/issues/548
const call = property => object => object[property]();
exports.assetNameName = call('name');
