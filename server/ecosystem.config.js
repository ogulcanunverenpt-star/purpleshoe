module.exports = {
  apps: [{
    name: 'firewall-ui',
    script: './cluster.js',
    instances: 1,
    exec_mode: 'fork',
    env: {
      NODE_ENV: 'production'
    }
  }]
};
