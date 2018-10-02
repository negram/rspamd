#!/usr/bin/env python

import argparse
import json
import os
import requests


# install path to repository mapping
# if path mapped to None, it means that the file should be ignored (i.e. test file/helper)
# first matched path counts
path_mapping = {
    "/home/circleci/install/share/rspamd/lib/fun.lua": None,
    "/home/circleci/install/share/rspamd/lib": "lualib",
    "/home/circleci/install/share/rspamd/rules" : "rules",
    "/home/circleci/project/test/lua": None,
    "/home/circleci/project/clang-plugin": None,
    "/home/circleci/project/test": None,
    "/home/circleci/project/CMakeFiles": None,
    "/home/circleci/project/contrib": None,
}

parser = argparse.ArgumentParser(description='')
parser.add_argument('--input', type=open, nargs='+', help='input files')
parser.add_argument('--output', type=str, required=True, help='output file)')
parser.add_argument('--root', type=str, required=True, help='repository root)')
parser.add_argument('--token', type=str, help='If present, the file will be uploaded to coveralls)')

def merge_coverage_vectors(c1, c2):
    assert(len(c1) == len(c2))
    
    for i in xrange(0, len(c1)):
        if c1[i] is None and c2[i] is None:
            pass
        elif type(c1[i]) is int and c2[i] is None:
            pass
        elif c1[i] is None and type(c2[i]) is int:
            c1[i] = c2[i]
        elif type(c1[i]) is int and type(c2[i]) is int:
            c1[i] += c2[i]
        else:
            raise RuntimeError("bad element types at %d: %s, %s", i, type(c1[i]), type(c1[i]))

    return c1


def normalize_name(name):
    name = os.path.normpath(name)
    if not os.path.isabs(name):
        name = os.path.abspath(repository_root + name)
    for k in path_mapping.keys():
        if name.startswith(k):
            if path_mapping[k] is None:
                return None
            else:
                # TODO: move repository_root to mapping
                name = name.replace(k, path_mapping[k])
                return name
    name = name.replace(repository_root, '')
    return name

def merge(files, j1):
    for sf in j1['source_files']:
        name = normalize_name(sf['name'])
        if name in files:
            files[name]['coverage'] = merge_coverage_vectors(files[name]['coverage'], sf['coverage'])
        else:
            sf['name'] = name
            files[name] = sf
            if not ('source' in sf):
                path = "%s/%s" % (repository_root, sf['name'])
                if os.path.isfile(path):
                    with open(path) as f:
                        files[name]['source'] = f.read()

    return files

if __name__ == '__main__':
    args = parser.parse_args()
    repository_root = os.path.abspath(args.root)
    j1 = json.loads(args.input[0].read())
    
    files = merge({}, j1)
    for i in xrange(1, len(args.input)):
        j2 = json.loads(args.input[i].read())
        files = merge(files, j2)
        
        if 'git' not in j1 and 'git' in j2:
            j1['git'] = j2['git']
        if 'service_name' not in j1 and 'service_name' in j2:
            j1['service_name'] = j2['service_name']
        if 'service_job_id' not in j1 and 'service_job_id' in j2:
            j1['service_job_id'] = j2['service_job_id']
        if not j1['service_job_id']:
            j1['service_job_id'] = os.environ['CIRCLE_BUILD_NUM']
        if os.environ['CIRCLECI']:
            j1['service_name'] = 'circleci'

    j1['source_files'] = files.values()

    with open(args.output, 'w') as f:
        f.write(json.dumps(j1))

    if not args.token is None:
        j1['repo_token'] = args.token
        print("sending data to coveralls...")
        r = requests.post('https://coveralls.io/api/v1/jobs', files={"json_file": json.dumps(j1)})
        response = json.loads(r.text)
        print "uploaded %s\nmessage:%s" % (response['url'], response['message'])
    # post https://coveralls.io/api/v1/jobs
    # print args


