'use strict';

const chai = require('chai');
const convertTime = require("../../steps/aws").convertTime

const expect = chai.expect;
describe('AWS', function () {
  it('converts time from strings to second based unix timestamps', () => {
    expect(convertTime("01/01/1970")).to.eq(0)
    expect(convertTime("12/31/2022")).to.eq(1672444800)
    expect(convertTime("01/01/2023")).to.eq(1672531200)
    expect(convertTime("01/01/2023") - convertTime("12/31/2022")).to.eq(60 * 60 * 24)
  });
});
