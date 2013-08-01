mixpanel-objc
=============

Mixpanel ObjC SDK for iOS 5 and up

This is a work-in-progress implementation of the Mixpanel SDK.

Features:

* Background concurrency via serial dispatch queue
* Optimization via caching and usage of background operations
* Usage of AFNetworking for API calls
* ARC support


Todo:

* Ensure reliability of recorded events (at present, events are sometimes recorded too many times)
* Observe wifi connection status and dynamically update cached eventEssentialProperties (known as deviceInfoProperties in mixpanel-iphone)
* Implement NSJSONSerialization instead of custom serializer

For known issues, see [Issues on Github](https://github.com/bondsy/mixpanel-objc/issues)