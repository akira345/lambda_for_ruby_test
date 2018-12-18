# -*- coding: utf-8 -*-
# 
# lambdaのRuby対応テスト
# S3に置いたYAMLファイルを基にSSL証明書の有効期限をチェックし、
# 期限が間近ならアラートメールを飛ばす。 
#
# 要 AWS SDK for Ruby V3

require "bundler/setup"
require 'aws-sdk-core'
require 'aws-sdk-s3'
require 'aws-sdk-ses'
require 'yaml'
require 'erb'
require 'socket'
require 'openssl'
require 'active_support'
require 'active_support/core_ext'

#通知する間隔
LIMIT_DAYS = [30,15,7,3,1]

# https://qiita.com/QUANON/items/47f862bc3abaf9f302ec より
def get_certificate(host)
  certificate = nil

  TCPSocket.open(host, 443) do |tcp_client|
    ssl_client = OpenSSL::SSL::SSLSocket.new(tcp_client)
    ssl_client.hostname = host
    ssl_client.connect
    certificate = ssl_client.peer_cert
    ssl_client.close
  end

  certificate
end
def time2str(time)
  d = time.strftime('%Y/%m/%d')
  w = %w(日 月 火 水 木 金 土)[time.wday]
  t = time.strftime('%H:%M:%S')

  "#{d} (#{w}) #{t}"
end

# ラムダ用関数
def check_certificate_limit(event:, context:)
  # アクセスキーはロールで付与するので、リージョン指定のみ
  pp "step0"
  begin
    s3 = Aws::S3::Client.new(
      region: ENV["AWS_REGION"].nil? ? "ap-northeast-1" : ENV["AWS_REGION"],
    )
    ses = Aws::SES::Client.new(
      region: "us-east-1", #バージニアリージョン
    )
  rescue => e
    puts "システムエラー"
    puts e
    exit (1)
  end
  pp "Step1"
  # S3より設定読み込み
  begin
    conf = s3.get_object(
        bucket: ENV['BUCKET_NAME'],
        key: "chk_ssl_limit_hosts.yml"
      ).body.read
      chk_hosts = YAML.load(conf)
      mail_from = chk_hosts['mail_from']
      hosts = chk_hosts['hosts']
  rescue Psych::SyntaxError
    puts "ERROR:YAMLファイルのパースに失敗"
    exit (1)
  rescue => e
    puts "設定の読み取りに失敗"
    puts e
    exit (1)
  end
  pp "step2"
  # SSLチェック
  hosts.each do |host|
    url = host["url"]
    begin
      pp "step3"
      certificate = get_certificate(url)
      pp "step3.5"
      not_after = certificate.not_after.in_time_zone('Japan')
      puts "日本時間：#{Time.now.in_time_zone('Japan')}"
      diff = ((not_after - Time.now.in_time_zone('Japan')) / 1.days) #時刻を取得するときは、ラムダ関数内ですること！
      puts url
      puts("有効期限: #{time2str(not_after)} (残り #{diff.to_i} 日)")
      pp "step4"
    rescue Errno::ETIMEDOUT
      puts "タイムアウトエラー：#{url}　続行します。"
      next
    rescue SocketError
      puts "サーバが見つかりません：#{url}　続行します。"
      next
    rescue Errno::ECONNREFUSED
      puts "サーバ接続エラー：#{url}　続行します。"
      next
    rescue => e
      pp e
      puts "システムエラー"
      exit(1)
    end
    pp "step5"
    # メール送信
    if LIMIT_DAYS.include?(diff.to_i)
      begin
        mail_body = ERB.new(open('mail.erb').read, nil, '-').result(binding)
        ses.send_email({
          source: mail_from,
          destination:{
            to_addresses: host["mails"],
          },
          message:{
            subject:{
              data: "SSL証明書有効期限通知(#{url})#{diff.to_i}日前",
              charset: "UTF-8",
            },
            body:{
              text:{
                data: mail_body,
                charset: "UTF-8",
              }
            }
          }
        })
      rescue => e
        puts "メール送信エラー。続行します。"
        puts e
        next
      end
    end
  end
  puts "正常終了！"
  return true
end
