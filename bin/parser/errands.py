import ipaddress
from solyaml import literal_unicode
from typing import Dict, Any, Optional, List
from schema import root
from selector import Selector

keywordsToIgnore = [
    "jobs"
]


class Errand:
    SSH_PORT = 2222 #const
    def __init__(self, name : str) -> None:
        self.name = name

    def generateErrandPropertiesFromCiFile(self, root, inputFile) -> dict:
        outputProperties = {}
        for propertyName, propertyValue in inputFile.items():
            if propertyName not in keywordsToIgnore:
                name = propertyName.split(".")[0]
                if name not in root.parameters:
                    raise ValueError("property '" + name + "' not found in schema")
                else:
                    parameter = root.parameters[name]
                    if "." in propertyName:
                        relativeName = propertyName.split(".", 1)[1]
                    else:
                        relativeName = "" 

                    if isinstance(parameter,Selector):
                       parameter.convertToBoshLiteManifestErrand(propertyName, relativeName, propertyValue, outputProperties)
                       # parameter.convertToBoshLiteManifest(propertyName, relativeName, propertyValue, outputProperties)
                       #if "." not in propertyName:
                       #    print("Done" , propertyName, "x" , relativeName, "x" , propertyValue )
                       #    outputProperties[propertyName] = {}
                       #    outputProperties[propertyName]["value"] = propertyValue
                       #else:
                       #   print(parameter.name)
                       #   print(propertyName, "x" , relativeName, "x" , propertyValue )

                           
        return outputProperties 

    def generateBoshLiteManifestJob(self, properties : Dict[str, Any], inputFile : Dict[str, Any], outFile: List[Dict[str, Any]]) -> None:
        output = {}
        output["name"] = self.name
        output["instances"] = 1
        output["lifecycle"] = "errand"
        output["templates"] = []
        output["templates"].append({"name": self.name, "release": "solace-messaging"})
        output["resource_pool"] = "common-resource-pool"
        output["networks"] = []
        output["networks"].append({})
        output["networks"][0]["name"] = "test-network"

        output["properties"] = {}
        output["properties"]["cf"] = {}
        output["properties"]["cf"]["admin_user"] = "admin"
        output["properties"]["cf"]["admin_password" ] = "admin"

        output["properties"]["domain"] = "local.pcfdev.io"
        output["properties"]["app_domains"] = []
        output["properties"]["app_domains"].append( "local.pcfdev.io" )

        output["properties"]["org"] = "solace"
        output["properties"]["space"] = "solace-messaging"

        output["properties"]["ssl"] = {}
        output["properties"]["ssl"]["skip_cert_verify"] = True

        output["properties"]["security"] = {}
        output["properties"]["security"]["user"] = "solacedemo"
        output["properties"]["security"]["password"] = "solacedemo"

        output["properties"]["solace_messaging"] = {}
        output["properties"]["solace_messaging"]["user"] = "solacedemo"
        output["properties"]["solace_messaging"]["password"] = "solacedemo"
        output["properties"]["solace_messaging"]["enable_global_access_to_plans"] = True

        output["properties"]["solace_vmr"] = {}

# Make VMR host and hosts list per
        for job in outFile["jobs"]:
           job_name = job["name"].lower().replace("-","_")
           # Skip Errands
           if job_name == self.name:
             continue
           if 'lifecycle' in job.keys() and job["lifecycle"] == "errand":
             continue
           host_list = []
           hosts_list = []
           output["properties"]["solace_vmr"][job_name] = {}
           output["properties"]["solace_vmr"][job_name]["host"] = []
           output["properties"]["solace_vmr"][job_name]["hosts"] = []
           for network in job["networks"]:
              for static_ip in network["static_ips"]:
                  hosts_list.append(static_ip)
                  if( len(host_list) < 1 ):
                    host_list.append(static_ip)
           if( len(host_list) > 0 ):           
             output["properties"]["solace_vmr"][job_name]["host"] = host_list
             output["properties"]["solace_vmr"][job_name]["hosts"] = hosts_list

# Simple/Flat properties
        output["properties"]["starting_port"] = properties["starting_port"]
        output["properties"]["vmr_admin_password"] = properties["admin_password"]

# Handle special structured properties ( tls_config, tcp_routes_config, ... )

## Custom generate
        customProperties = self.generateErrandPropertiesFromCiFile(root,inputFile)

        output["properties"].update(customProperties)

        outFile["jobs"].append(output)

# Define the errands
deploy_all = Errand("deploy-all")
delete_all = Errand("delete-all")
