#!/bin/sh

domain='http://7xs9f1.com1.z0.glb.clouddn.com'

sed -i "s?(.*/pic/?(${domain}/pic/?g" `grep "/pic/" -rl ./content`
