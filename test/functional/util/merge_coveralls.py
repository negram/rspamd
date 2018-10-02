#!/usr/bin/env python

import argparse
import json
import os
import requests


# install path to repository mapping
# if path mapped to None, it means that the file should be ignored (i.e. test file/helper)
# first matched path counts.
# terminating slash should be added for directories 
path_mapping = [
    ("${install-dir}/share/rspamd/lib/fun.lua", None),
    ("${install-dir}/share/rspamd/lib/", "lualib/"),
    ("${install-dir}/share/rspamd/rules/" , "rules/"),
    ("${install-dir}/share/rspamd/lib/torch/" , None),
    ("${build-dir}/CMakeFiles/", None),
    ("${build-dir}/contrib/", None),
    ("${build-dir}/test", None),
    ("${project-root}/test/lua/", None),
    ("${project-root}/test/", None),
    ("${project-root}/clang-plugin/", None),
    ("${project-root}/CMakeFiles/", None),
    ("${project-root}/contrib/", None),
    ("${project-root}/", ""),
    ("contrib/", None),
    ("CMakeFiles/", None),
]

parser = argparse.ArgumentParser(description='')
parser.add_argument('--input', type=open, required=True, nargs='+', help='input files')
parser.add_argument('--output', type=str, required=True, help='output file)')
parser.add_argument('--root', type=str, required=False, default="/home/circleci/project", help='repository root)')
parser.add_argument('--install-dir', type=str, required=False, default="/home/circleci/install", help='install root)')
parser.add_argument('--build-dir', type=str, required=False, default="/home/circleci/build", help='build root)')
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
    orig_name = name
    name = os.path.normpath(name)
    if not os.path.isabs(name):
        name = os.path.abspath(repository_root + "/" + name)
    for k in path_mapping:
        if name.startswith(k[0]):
            if k[1] is None:
                return None
            else:
                name = k[1] + name[len(k[0]):]
                break
    return name

def merge(files, j1):
    for sf in j1['source_files']:
        name = normalize_name(sf['name'])
        if name is None:
            continue
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

def prepare_path_mapping():
    for i in xrange(0, len(path_mapping)):
        new_key = path_mapping[i][0].replace("${install-dir}", install_dir)
        new_key = new_key.replace("${project-root}", repository_root)
        new_key = new_key.replace("${build-dir}", build_dir)
                    
        path_mapping[i] = (new_key, path_mapping[i][1])

if __name__ == '__main__':
    args = parser.parse_args()

    repository_root = os.path.abspath(os.path.expanduser(args.root))
    install_dir = os.path.normpath(os.path.expanduser(args.install_dir))
    build_dir = os.path.normpath(os.path.expanduser(args.build_dir))

    prepare_path_mapping()

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
        if not j1['service_job_id'] and 'CIRCLE_BUILD_NUM' in os.environ:
            j1['service_job_id'] = os.environ['CIRCLE_BUILD_NUM']
        if 'CIRCLECI' in os.environ and os.environ['CIRCLECI']:
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


