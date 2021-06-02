
const wp = require('@cypress/webpack-preprocessor');
const webpackConfig = require('../../webpack.config');

module.exports = (on, config) => {
  const options = {
    webpackOptions: webpackConfig(null, {mode: 'dev'}),

  }
  on('file:preprocessor', wp(options))
  require('@cypress/code-coverage/task')(on, config)

  return config
}
