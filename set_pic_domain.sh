#!/bin/sh

domain='https://image.fatedier.com'

sed -i "s?(.*/pic/?(${domain}/pic/?g" `grep "/pic/" -rl ./content`
