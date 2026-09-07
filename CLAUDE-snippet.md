# Optional agent instruction for cpcv

When the user refers to a recently copied Windows screenshot, inspect the
configured remote image path directly. By default that is:

```text
~/clipboard-images/latest.png
```

If the cpcv configuration uses another `RemoteDir`, substitute that path.
Do not assume a particular SSH hostname, Linux username, Cloudflare setup, or
agent product.
