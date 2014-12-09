var _ = require('underscore');
var async = require('async');
var fs = require('fs');
var request = require('request');
var util = require('util');
var toml = require('toml');
var express = require('express');
var bodyParser = require('body-parser');

var app = express();
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: false }));

var configPath = process.env.HOME + '/.config/slack-groupme-gateway/config.toml';
var configData = fs.readFileSync(configPath);
var config = toml.parse(configData);
config.gateways = _.map(config.gateways, function (entry) {
  var groupme = _.findWhere(config.groupme.groups, {group_id: entry.groupme})
  if (groupme === undefined) {
    throw "gateway config error: unknown groupme '" + entry.groupme + "'";
  }
  var slack = _.findWhere(config.slack.channels, {name: entry.slack})
  if (slack === undefined) {
    throw "gateway config error: unknown slack '" + entry.slack + "'";
  }
  return { groupme: groupme, slack: slack };
});

var groupmeQueue = async.queue(function (task, callback) {
  var text = '[' + task.username + '] ' + task.text;
  request.post({
    url: 'https://api.groupme.com/v3/bots/post',
    json: {
      bot_id: task.group.bot_id,
      text: text
    }
  }, function (error, response, body) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      // success
    } else {
      console.log('groupme error: ' + response.statusCode);
      console.log(body);
    }
    callback(error)
  });
}, 1);
var slackQueue = async.queue(function (task, callback) {
  var username = task.username + ' [groupme]';
  var attachments = _.map(task.attachments, function (url) {
    return {
      fallback: task.fallback,
      text: url
    }
  });
  var json = {
    text: task.text,
    attachments: attachments,
    channel: '#' + task.channel.name,
    parse: 'full',
    username: username
  };
  if (task.icon_url) {
    json.icon_url = task.icon_url;
  }
  request.post({
    url: config.slack.webhook_url,
    json: json
  }, function (error, response, body) {
    if (response.statusCode == 200) {
      // success
    } else {
      console.log('slack error: ' + response.statusCode);
      console.log(body);
    }
    callback(error);
  })
}, 1);

app.post('/groupme', function (req, res) {
  var group_id = req.body.group_id;
  var gateway = _.find(config.gateways, function (gateway) { return gateway.groupme.group_id == group_id });
  if (gateway === undefined) {
    console.log('error: unknown groupme group_id ' + group_id);
    res.status(400).end('unknown group_id');
    return;
  }
  if (req.body.user_id == gateway.groupme.user_id) {
    // it just received its own message, ignore it
    res.status(200).end("Ignoring message from self");
    return;
  } else if (!gateway.groupme.user_id) {
    // we don't know what the user_id is
    // ignore all messages for the moment
    console.log(util.format("No user_id set for group %s, ignoring message: %j", gateway.groupme.name, req.body));
    res.status(200).end("Ignoring message to group without user_id configured");
    return;
  }
  var text = req.body.text;
  var attachments = req.body.attachments;
  var fallback = undefined;
  if (attachments) {
    var unknown = _.filter(attachments, function (obj) { return obj.type != "image" && obj.type != "location"; });
    if (!_.isEmpty(unknown)) {
      console.log(util.format("groupme: unknown attachments: %j", unknown));
    }
    attachments = _.pluck(_.filter(attachments, function (obj) { return obj.type == "image"; }), 'url');
    fallback = "GroupMe image attachment";
  }
  if (!text && !attachments) {
    console.log(util.format('/groupme POST without text or attachments:\n%j', req.body));
    res.status(400).end("Expected text or attachments");
    return;
  }
  slackQueue.push({
    username: req.body.name,
    text: req.body.text,
    attachments: attachments,
    fallback: fallback,
    channel: gateway.slack,
    icon_url: req.body.avatar_url
  });
  res.status(200).end("Request queued");
});
app.post('/slack', function (req, res) {
  var channel = req.body.channel_name;
  var gateway = _.find(config.gateways, function (gateway) { return gateway.slack.name == channel });
  if (gateway === undefined) {
    console.log('error: unknown slack channel ' + channel);
    res.status(400).end('unknown channel');
    return;
  }
  var token = req.body.token;
  if (token != gateway.slack.token) {
    console.log(util.format('error: invalid or missing token from slack endpoint: %j', req.body));
    res.status(400).end('Invalid or missing token');
    return;
  }
  if (req.body.user_id == config.slack.user_id) {
    // it just received its own message, ignore it
    res.status(200).end("Ignoring message from self");
    return;
  }

  groupmeQueue.push({
    username: req.body.user_name,
    text: req.body.text,
    group: gateway.groupme
  });
  res.status(200).end("Request queued");
});

var port = config.port || 5287;
app.listen(port);
var servername = config.server_name || "0.0.0.0";
console.log('Server listening on http://' + servername + ':' + port + '/');
