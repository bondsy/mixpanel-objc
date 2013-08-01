mixpanel-objc
=============

Mixpanel ObjC SDK for iOS 5 and up

This is a work-in-progress implementation of the Mixpanel SDK.

Features:

* Background concurrency via serial dispatch queue
* ARC support
* Improved factorization
* Optimization via caching and usage of background 

Todo:

* Ensure reliability of recorded events (at present, events are sometimes recorded too many times)
* Observe wifi connection status and dynamically update cached deviceInfoProperties
* Implement NSJSONSerialization instead of custom serializer