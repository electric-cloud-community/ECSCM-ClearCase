@files = (
    ['//property[propertyName="ECSCM::ClearCase::Cfg"]/value', 'ClearCaseCfg.pm'],
    ['//property[propertyName="ECSCM::ClearCase::Driver"]/value', 'ClearCaseDriver.pm'],
    ['//property[propertyName="checkout"]/value', 'clearCaseCheckoutForm.xml'],
    ['//property[propertyName="preflight"]/value', 'clearCasePreflightForm.xml'],
    ['//property[propertyName="sentry"]/value', 'clearCaseSentryForm.xml'],
    ['//property[propertyName="trigger"]/value', 'clearCaseTriggerForm.xml'],
    ['//property[propertyName="createConfig"]/value', 'clearCaseCreateConfigForm.xml'],
    ['//property[propertyName="editConfig"]/value', 'clearCaseEditConfigForm.xml'],
    ['//property[propertyName="ec_setup"]/value', 'ec_setup.pl'],
	['//procedure[procedureName="CheckoutCode"]/propertySheet/property[propertyName="ec_parameterForm"]/value', 'clearCaseCheckoutForm.xml'],
	['//procedure[procedureName="Preflight"]/propertySheet/property[propertyName="ec_parameterForm"]/value', 'clearCasePreflightForm.xml'],
    ['//procedure[procedureName="CheckoutCode"]/step[stepName="checkParams"]/command' , 'checkparams.pl'],
);
